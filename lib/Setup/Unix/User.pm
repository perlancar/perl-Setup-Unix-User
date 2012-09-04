package Setup::Unix::User;

use 5.010;
use strict;
use warnings;
use Log::Any '$log';

use File::chdir;
use File::Find;
use File::Slurp;
use PerlX::Maybe;
use Text::Password::Pronounceable;
use Unix::Passwd::File;

require Exporter;
our @ISA       = qw(Exporter);
our @EXPORT_OK = qw(setup_unix_user);

# VERSION

our %SPEC;

sub _rand_pass {
    Text::Password::Pronounceable->generate(10, 16);
}

my %common_args = (
    etc_dir => {
        summary => 'Location of passwd files',
        schema  => ['str*' => {default=>'/etc'}],
    },
    user => {
        schema  => 'str*',
        summary => 'User name',
    },
);

$SPEC{deluser} = {
    v => 1.1,
    summary => 'Delete user',
    args => {
        %common_args,
    },
    features => {
        tx => {v=>2},
        idempotent => 1,
    },
};
sub deluser {
    my %args = @_;

    my $tx_action = $args{-tx_action} // '';
    my $dry_run   = $args{-dry_run};
    my $user      = $args{user} or return [400, "Please specify user"];
    $user =~ $Unix::Passwd::File::re_user
        or return [400, "Invalid user"];
    my %ca        = (etc_dir => $args{etc_dir}, user=>$user);
    my $res;

    if ($tx_action eq 'check_state') {
        $res = Unix::Passwd::File::get_user(%ca);
        return $res unless $res->[0] == 200 || $res->[0] == 404;

        return [304, "User $user already doesn't exist"] if $res->[0] == 404;
        $log->info("(DRY) Deleting Unix user $user ...") if $dry_run;
        return [200, "Fixable", undef, {undo_actions=>[
            [adduser => {%ca, uid => $res->[2]{uid}}],
        ]}];
    } elsif ($tx_action eq 'fix_state') {
        $log->info("Deleting Unix user $user ...");
        return Unix::Passwd::File::delete_user(%ca);
    }
    [400, "Invalid -tx_action"];
}

$SPEC{adduser} = {
    v => 1.1,
    summary => 'Add user',
    args => {
        %common_args,
        uid => {
            summary => 'Add with specified UID',
            description => <<'_',

If not specified, will search an unused UID from `min_uid` to `max_uid`.

_
            schema => 'int',
        },
        min_uid => {
            schema => [int => {default=>1000}],
        },
        max_uid => {
            schema => [int => {default=>65534}],
        },
        gid => {
            summary => 'When creating group, use specific GID',
            description => <<'_',

If not specified, will search an unused GID from `min_gid` to `max_gid`.

_
            schema => 'int',
        },
        min_gid => {
            schema => [int => {default=>1000}],
        },
        max_gid => {
            schema => [int => {default=>65534}],
        },
        gecos => {
            schema => 'str',
        },
        password => {
            schema => 'str',
        },
        home => {
            schema => 'str',
        },
        shell => {
            schema => 'str',
        },
    },
    features => {
        tx => {v=>2},
        idempotent => 1,
    },
};
sub adduser {
    my %args = @_;

    my $tx_action = $args{-tx_action} // '';
    my $dry_run   = $args{-dry_run};
    my $user      = $args{user} or return [400, "Please specify user"];
    $user =~ $Unix::Passwd::File::re_user
        or return [400, "Invalid user"];
    my $uid       = $args{uid};
    my %ca0       = (etc_dir => $args{etc_dir});
    my %ca        = (%ca0, user=>$user);
    my $res;

    if ($tx_action eq 'check_state') {
        $res = Unix::Passwd::File::get_user(%ca);
        return $res unless $res->[0] == 200 || $res->[0] == 404;

        if ($res->[0] == 200) {
            if (!defined($uid) || $uid == $res->[2]{uid}) {
                return [304, "User $user already exists"];
            } else {
                return [412, "User $user already exists but with different ".
                            "UID ($res->[2]{uid}, wanted $uid)"];
            }
        } else {
            $log->info("(DRY) Adding Unix user $user ...") if $dry_run;
            return [200, "User $user needs to be added", undef,
                    {undo_actions=>[
                        [deluser => {%ca}],
            ]}];
        }
    } elsif ($tx_action eq 'fix_state') {
        # we don't want to have to get_user() when fixing state, to reduce
        # number of read passes to the passwd files
        $log->info("Adding Unix user $user ...");
        $res = Unix::Passwd::File::add_user(
            %ca,
            maybe uid     => $uid,
            min_uid => $args{min_uid} // 1000,
            max_uid => $args{max_uid} // 65534,
            maybe group   => $args{group},
            maybe gid     => $args{gid},
            min_gid => $args{min_gid} // 1000,
            max_gid => $args{max_gid} // 65534,
            maybe pass    => $args{pass},
            maybe gecos   => $args{gecos},
            maybe home    => $args{home},
            maybe shell   => $args{shell},
        );
        if ($res->[0] == 200) {
            $args{-stash}{result}{uid} = $uid;
            $args{-stash}{result}{gid} = $res;
            return [200, "Created"];
        } else {
            return $res;
        }
    }
    [400, "Invalid -tx_action"];
}
__END__

$SPEC{setup_unix_user} = {
    v           => 1.1,
    summary     => "Setup Unix user (existence, group memberships)",
    description => <<'_',

On do, will create Unix user if not already exists. And also make sure user
belong to specified groups (and not belong to unwanted groups). Return the
created UID/GID in the result.

On undo, will delete Unix user (along with its initially created home dir and
files) if it was created by this function. Also will restore old group
memberships.

_
    args => {
        user => {
            schema => 'str*',
            summary => 'User name',
        },
        should_already_exist => {
            schema => ['bool' => {default => 0}],
            summary => 'If set to true, require that user already exists',
            description => <<'_',

This can be used to fix user membership, but does not create user when it
doesn't exist.

_
        },
        member_of => {
            schema => ['array' => {of=>'str*'}],
            summary => 'List of Unix group names that the user must be '.
                'member of',
            description => <<'_',

If not specified, member_of will be set to just the primary group. The primary
group will always be added even if not specified.

_
        },
        not_member_of => {
            schema  => ['array' => {of=>'str*'}],
            summary => 'List of Unix group names that the user must NOT be '.
                'member of',
        },
        min_new_uid => {
            schema  => ['int' => {default=>1000}],
            summary => 'Set minimum UID when creating new user',
        },
        max_new_uid => {
            schema  => ['int' => {default => 65534}],
            summary => 'Set maximum UID when creating new user',
        },
        min_new_gid => {
            schema  => 'int',
            summary => 'Set minimum GID when creating new group',
            description => 'Default is UID',
        },
        max_new_gid => {
            schema  => 'int',
            summary => 'Set maximum GID when creating new group',
            description => 'Default follows max_new_uid',
        },
        new_password => {
            schema  => 'str',
            summary => 'Set password when creating new user',
            description => 'Default is a random password',
        },
        new_gecos => {
            schema  => ['str' => {default=>''}],
            summary => 'Set gecos (usually, full name) when creating new user',
        },
        new_home_dir => {
            schema  => 'str',
            summary => 'Set home directory when creating new user, '.
                'defaults to /home/<username>',
        },
        new_home_dir_mode => {
            schema  => [int => {default => 0700}],
            summary => 'Set permission mode of home dir '.
                'when creating new user',
        },
        new_shell => {
            schema  => ['str' => {default => '/bin/bash'}],
            summary => 'Set shell when creating new user',
        },
        skel_dir => {
            schema  => [str => {default => '/etc/skel'}],
            summary => 'Directory to get skeleton files when creating new user',
        },
        create_home_dir => {
            schema  => [bool => {default=>1}],
            summary => 'Whether to create homedir when creating new user',
        },
        use_skel_dir => {
            schema  => [bool => {default=>1}],
            summary => 'Whether to copy files from skeleton dir '.
                'when creating new user',
        },
        primary_group => {
            schema  => 'str',
            summary => "Specify user's primary group",
            description => <<'_',

In Unix systems, a user must be a member of at least one group. This group is
referred to as the primary group. By default, primary group name is the same as
the user name. The group will be created if not exists.

_
        },
    },
    features => {
        tx => {v=>2},
        idempotent => 1,
    },
};
sub setup_unix_user {
    my %args = @_;

    # TMP, SCHEMA
    my $user = $args{user} or return [400, "Please specify user"];
    $user =~ $Unix::Passwd::File::re_user
        or return [400, "Invalid user"];
    my $new_password      = $args{new_password} // _rand_pass();
    my $new_gecos         = $args{new_gecos}    // "";
    my $new_home_dir      = $args{new_home_dir} // "/home/$user";
    my $new_home_dir_mode = $args{new_home_dir_mode} // 0700;
    my $new_shell         = $args{new_shell} // "/bin/bash";
    my $create_home_dir   = $args{create_home_dir} // 1;
    my $use_skel_dir      = $args{use_skel_dir} // 1;
    my $skel_dir          = $args{skel_dir} // "/etc/skel";
    my $primary_group     = $args{primary_group} // $args->{name};
    my $member_of         = $args{member_of} // [];
    push @$member_of, $primary_group
        unless $primary_group ~~ @$member_of;
    my $not_member_of     = [];
    for (@$member_of) {
        return [400, "Group $_ is in member_of and not_member_of"]
            if $_ ~~ @$not_member_of;
    }

    my $res;
    my (@do, @undo);

    my $res = Unix::Passwd::File::list_users_and_groups();

    # check state:
    # - check group $user exists -> fix
    # - check usernya exist -> fix
    # - check semua group lain di member_of harus exist
    # - check semua group di member_of harus exist
    # - create home dir -> fix dg mkdir dan kopi skel
    #

    if ($primary_group eq $user) {
        my @g = $pu->group($name);
        if (!@g) {
            $log->infof("nok: unix group $name doesn't exist");
            push @steps, ["setup_unix_group"];
        }
    }

        my @u = $pu->user($name);
        if (!@u) {
            $log->infof("nok: unix user $name doesn't exist");
            return [412, "user must already exist"]
                if $args->{should_already_exist};
            push @steps, ["create"];
            last;
        }

        my $uid = $u[1];
        my $gid = $u[2];
        my @membership = _get_user_membership($name, $pu);
        for (@{$args->{member_of}}) {
            my @g = $pu->group($_);
            if (!$g[0]) {
                $log->info("unix user $name should be member of $_ ".
                               "but the group doesn't exist, ignored");
                next;
            }
            unless ($_ ~~ @membership) {
                $log->info("nok: unix user $name should be ".
                               "member of $_ but isn't");
                push @steps, ["add_group", $_];
            }
        }
        for (@{$args->{not_member_of}}) {
            if ($_ ~~ @membership) {
                $log->info("nok: unix user $name should NOT be ".
                               "member of $_ but is");
                push @steps, ["remove_group", $_];
            }
        }

        [200, "OK", \@steps];
    }

}

1;
# ABSTRACT: Setup Unix user (existence, home dir, group memberships)

=head1 FAQ

=head2 How to create user with a specific UID and/or GID?

Set C<min_new_uid> and C<max_new_uid> (and/or C<min_new_gid> and C<max_new_gid>)
to your desired values. Note that the function will report failure if when
wanting to create a user, the desired UID is already taken. But the function
will not report failure if the user already exists, even with a different UID.

=head2 How to create user without creating a group with the same name as that user?

By default, C<primary_group> is set to the same name as the user. You can set it
to an existing group, e.g. "users" and the setup function will not create a new
group with the same name as user.


=head1 SEE ALSO

L<Setup>

L<Setup::Unix::Group>

=cut
