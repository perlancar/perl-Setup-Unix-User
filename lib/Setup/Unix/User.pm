package Setup::Unix::User;

use 5.010;
use strict;
use warnings;
use Log::Any '$log';

use List::Util qw(first);
use PerlX::Maybe;
use Setup::File;
use Unix::Passwd::File;

require Exporter;
our @ISA       = qw(Exporter);
our @EXPORT_OK = qw(setup_unix_user);

# VERSION

our %SPEC;

sub _rand_pass {
    require Text::Password::Pronounceable;
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

my %adduser_args = (
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
    pass => {
        schema => 'str',
    },
    home => {
        schema => 'str',
    },
    shell => {
        schema => 'str',
    },
);
$SPEC{adduser} = {
    v => 1.1,
    summary => 'Add user',
    args => {
        %common_args,
        %adduser_args,
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

$SPEC{add_delete_user_groups} = {
    v => 1.1,
    summary => "Add/delete user from group memberships",
    args => {
        %common_args,
        add_to => {
            schema => ['array*' => {of=>'str*'}],
            req => 1,
        },
        delete_from => {
            schema => ['array*' => {of=>'str*'}],
            req => 1,
        },
    },
    features => {
        tx => {v=>2},
        idempotent => 1,
    },
};
sub add_delete_user_groups {
    my %args = @_;

    my $tx_action = $args{-tx_action} // '';
    my $dry_run   = $args{-dry_run};
    my $user      = $args{user} or return [400, "Please specify user"];
    $user =~ $Unix::Passwd::File::re_user
        or return [400, "Invalid user"];
    my $add_to    = $args{add_to}
        or return [400, "Please specify add_to"];
    my $del_from  = $args{delete_from}
        or return [400, "Please specify delete_from"];
    my %ca        = (etc_dir=>$args{etc_dir}, user=>$user);
    my $res;

    if ($tx_action eq 'check_state') {
        $res = Unix::Passwd::File::get_user_groups(%ca);
        return $res unless $res->[0] == 200;
        my $cur_groups = $res->[2];

        my (@needs_add, @needs_del);
        for (@$add_to) {
            push @needs_add, $_ unless $_ ~~ $cur_groups;
        }
        for (@$del_from) {
            push @needs_del, $_ if     $_ ~~ $cur_groups;
        }

        if (@needs_add || @needs_del) {
            $log->infof(
                "(DRY) Fixing user %s's membership, groups to add to: %s, ".
                    "groups to delete from: %s ...",
                $user, \@needs_add, \@needs_del) if $dry_run;
            return [200, "User $user needs to fix membership, groups to add ".
                      "to: (".join(", ",@needs_add)."), groups to delete from ".
                          "(".join(", ",@needs_del).")",
                    undef, {undo_actions=>[
                        [add_delete_user_groups=>{
                            %ca,
                            add_to=>\@needs_del, delete_from=>\@needs_add}],
                    ]}
                  ];
        } else {
            return [304, "User $user already belongs to the wanted groups"];
        }
    } elsif ($tx_action eq 'fix_state') {
        # we don't want to have to get_user_groups() when fixing state, to
        # reduce number of read passes to the passwd files
        $log->infof("Fixing user %s's membership, groups to add to: %s, ".
                        "groups to delete from: %s ...",
                    $user, $add_to, $del_from);
        return Unix::Passwd::File::add_delete_user_groups(
            %ca, add_to=>$add_to, delete_from=>$del_from);
    }
    [400, "Invalid -tx_action"];
}

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
        should_exist => {
            schema => ['bool' => {default => 1}],
            summary => 'Whether user should exist',
        },
        should_already_exist => {
            schema => 'bool',
            summary => 'Whether user should already exist',
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
        (map {("new_$_" => $adduser_args{$_})} keys %adduser_args),
        create_home => {
            schema  => [bool => {default=>1}],
            summary => 'Whether to create home directory when creating user',
        },
        ## new_home_mode? new_home_group? fix existing home dir?
        #home_mode => {
        #    schema  => [str => {default=>0700}],
        #    summary => 'Permission mode when creating home directory',
        #},
        use_skel => {
            schema  => [bool => {default=>1}],
            summary => 'Whether to copy files from skeleton dir '.
                'when creating user',
        },
        skel_dir => {
            schema  => [str => {default => '/etc/skel'}],
            summary => 'Directory to get skeleton files when creating user',
        },
    },
    features => {
        tx => {v=>2},
        idempotent => 1,
    },
};
sub setup_unix_user {
    require File::Copy::Undoable;
    require File::Trash::Undoable;

    my %args = @_;

    # TMP, SCHEMA
    my $dry_run = $args{-dry_run};
    my $taid    = $args{-tx_action_id}
        or return [400, "Please specify -tx_action_id"];
    my $user    = $args{user} or return [400, "Please specify user"];
    $user =~ $Unix::Passwd::File::re_user
        or return [400, "Invalid user"];
    my $should_exist  = $args{should_exist} // 1;
    my $should_aexist = $args{should_already_exist};
    my $create_home   = $args{create_home} // 1;
    #my $home_mode     = $args{home_mode} // 0700;
    my $use_skel      = $args{use_skel} // 1;
    my $skel_dir      = $args{skel_dir} // "/etc/skel";
    my $group         = $args{group} // $args{user};
    my $member_of     = $args{member_of} // [];
    push @$member_of, $group unless $group ~~ @$member_of;
    my $not_member_of = [];
    for (@$member_of) {
        return [400, "Group $_ is in member_of and not_member_of"]
            if $_ ~~ @$not_member_of;
    }
    my %ca0           = (etc_dir=>$args{etc_dir});
    my %ca            = (%ca0, user=>$user);

    # we use this function so we reduce the number of read passes through the
    # passwd files.
    my $res    = Unix::Passwd::File::list_users_and_groups(%ca0, detail=>1);
    return $res unless $res->[0] == 200;
    my $users  = $res->[2][0];
    my $groups = $res->[2][1];
    my $uentry = first {$_->{user} eq $user} @$users;
    my $exists = !!$uentry;

    my (@do, @undo);

    my %addargs = (
        %ca,
        maybe group   => $args{group},
        maybe uid     => $args{new_uid},
        maybe min_uid => $args{min_new_uid},
        maybe max_uid => $args{max_new_uid},
        maybe gid     => $args{new_gid},
        maybe min_gid => $args{min_new_gid},
        maybe max_gid => $args{max_new_gid},
        maybe pass    => $args{new_pass},
        maybe gecos   => $args{new_gecos},
        maybe home    => $args{new_home},
        maybe shell   => $args{new_shell},
    );

    #$log->tracef("user=%s, exists=%s, should_exist=%s, ", $user, $exists, $should_exist);
    {
        # create user
        if ($exists) {
            if (!$should_exist) {
                $log->info("(DRY) Deleting user $user ...");
                push    @do  , [deluser=>{%ca}];
                unshift @undo, [adduser=>\%addargs];
                last;
            }
        } else {
            if ($should_aexist) {
                return [412, "User $user should already exist"];
            } elsif ($should_exist) {
                $log->info("(DRY) Adding user $user ...");
                push    @do  , [adduser=>\%addargs];
                unshift @do  , [deluser=>{%ca}];
            }
        }

        # fix group membership
        if ($exists) {
            my (@needs_add, @needs_del);
            for my $l (@$groups) {
                my @mm = split /,/, $l->[-1];
                push @needs_add, $l->[0]
                    if $l->[0] ~~ @$member_of     && !($user ~~ @mm);
                push @needs_del, $l->[0]
                    if $l->[0] ~~ @$not_member_of &&  ($user ~~ @mm);
            }
            push @do,
                [add_delete_user_groups=>{
                    %ca,
                    add_to=>\@needs_add, delete_from=>\@needs_del}]
                    if @needs_add || @needs_del;
        } else {
            push @do,
                [add_delete_user_groups=>{
                    %ca,
                    add_to=>$member_of, delete_from=>$not_member_of}];
        }

        # create homedir
        my $home = $uentry->{home};
        if ($create_home && (!$exists || !(-d $home))) {
            $log->info("(DRY) Creating home directory for $user ...");
            if ($use_skel) {
                return [412, "Skeleton directory $skel_dir doesn't exist"]
                    unless (-d $skel_dir);
                push @do, (
                    ["File::Copy::Undoable" => {
                        source=>$skel_dir,
                        target=>$home, target_owner=>$user,
                    }],
                );
                unshift @undo, (
                    ["File::Trash::Undoable::trash" => {
                        path=>$home, suffix=>substr($taid,0,8)}],
                );
            } else {
                push @do, (
                    ["Setup::File::mkdir" => {path=>$home}],
                );
                unshift @undo, (
                    ["Setup::File::mkdir" => {path=>$home}],
                );
            }
            push @do, (
                ["Setup::File::chmod" => {path=>$home, mode=>0700}], #$home_mode
            );
        }
    } #block

    if (@do) {
        return [200, "", undef, {do_actions=>\@do, undo_actions=>\@undo}];
    } else {
        return [304, "Already fixed"];
    }
}

1;
# ABSTRACT: Setup Unix user (existence, home dir, group memberships)

=head1 FAQ

=head2 How to create user without creating a group with the same name as that user?

By default, C<group> is set to the same name as the user. This will create group
with the same name as the user (if the group didn't exist). You can set C<group>
to an existing group, e.g. C<users> and the setup function will not create a new
group with the same name as user. But note that the group must already exist (if
it does not, you can create it first using L<Setup::Unix::Group>).


=head1 SEE ALSO

L<Setup>

L<Setup::Unix::Group>

=cut
