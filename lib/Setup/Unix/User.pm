package Setup::Unix::User;

use 5.010;
use strict;
use warnings;
use Log::Any '$log';

use File::chdir;
use File::Find;
use File::Slurp;
use Perinci::Sub::Gen::Undoable 0.13 qw(gen_undoable_func);
use Text::Password::Pronounceable;

require Exporter;
our @ISA       = qw(Exporter);
our @EXPORT_OK = qw(setup_unix_user);

# VERSION

sub _create_pu_object {
    Setup::Unix::Group::_create_pu_object(@_);
}

sub _get_user_membership {
    my ($name, $pu) = @_;
    my @res;
    for ($pu->groups) {
        my @g = $pu->group($_);
        push @res, $_ if $name ~~ @{$g[1]};
    }
    @res;
}

sub _rand_pass {
    Text::Password::Pronounceable->generate(10, 16);
}

sub _check_or_fix {
    my ($which, $args, $step, $undo, $r, $rmeta) = @_;
    my $name = $args->{name};

    my ($pu, $passwd_path, $group_path, $shadow_path, $gshadow_path) =
        _create_pu_object($args);

    my ($uid, $gid);

    if ($step->[0] eq 'create') { # arg: [uid, gid, [encp, gecos, home, sh]]
        $uid = undef; $gid = undef;
        my @u = $pu->user($name);
        if (@u) {
            if (defined($step->[1])) {
                if ($step->[1] ne $u[1]) {
                    return [412, "User already exists, but with different ".
                                "UID $u[1] (we need to create UID $step->[1])"];
                }
                $uid = $u[1];
            }
            if (defined($step->[2])) {
                if ($step->[2] ne $u[2]) {
                    return [412, "User already exists, but with different ".
                                "GID $u[2] (we need to create GID $step->[2])"];
                }
                $gid = $u[2];
            }
            return [304, "User already exists with correct UID/GID"];
        }

        my $found = defined($uid);
        my $minuid = $args->{min_new_uid} // 1;
        my $maxuid = $args->{max_new_uid} // 65535;
        if (!$found) {
            $log->trace("finding an unused UID ...");
            my @uids = map {($pu->user($_))[1]} $pu->users;
            $uid = $minuid;
            while (1) {
                last if $uid > $maxuid;
                unless ($uid ~~ @uids) {
                    $log->tracef("found unused UID: %d", $uid);
                    $found++;
                    last;
                }
                $uid++;
            }
        }
        return [412, "Can't find unused UID"] unless $found;

        $found = defined($gid);
        my $mingid = $args->{min_new_gid}   // $uid;
        my $maxgid = $args->{max_new_gid}   // $maxuid;
        my $pgroup = $args->{primary_group} // $name;
        if (!$found) {
            my @g = $pu->group($pgroup);
            if ($g[0]) {
                $gid = $g[0];
            } else {
                $log->trace("Creating primary group for user $name: ".
                                "$pgroup ...");
                my %s_args = (
                    name          => $pgroup,
                    _passwd_path  => $passwd_path,
                    _shadow_path  => $shadow_path,
                    _group_path   => $group_path,
                    _gshadow_path => $gshadow_path,
                    min_new_gid   => $mingid,
                    max_new_gid   => $maxgid,
                );
                my $res = setup_unix_group(
                    %s_args, -undo_action => $save_undo ? 'do' : undef);
                $log->tracef("res from setup_unix_group: %s", $res);
                    if ($res->[0] != 200) {
                        $err = "Can't setup Unix group $pgroup: ".
                            "$res->[0] - $res->[1]";
                    } else {
                        $gid = $res->[2]{gid};
                        unshift @$undo_steps,
                            ["unsetup_unix_group", \%s_args,
                             $res->[3]{undo_data}];
                    }
                }
            }

            $log->trace("Creating Unix user $name ...");
            if (defined $step->[3]) {
                $pu->user($name, $step->[3], $step->[1], $step->[2],
                          $step->[4], $step->[5], $step->[6]);
            } else {
                $pu->user($name, $pu->encpass($new_password), $uid, $gid,
                          $new_gecos, $new_home_dir, $new_shell);
            }
            if ($Passwd::Unix::Alt::errstr) {
                $err = "Can't add Unix passwd entry: ".
                    $Passwd::Unix::Alt::errstr;
            } else {
                unshift @$undo_steps, ["delete"];
            }

            for my $gi (@$member_of) {
                my @g = $pu->group($gi); # XXX check error
                unless ($g[0]) {
                    $log->warn("group $gi doesn't exist, skipped");
                    next;
                }
                unless ($name ~~ @{$g[1]}) {
                    $log->trace("Adding user $name to group $gi ...");
                    push @{$g[1]}, $name;
                    $pu->group($gi, $g[0], $g[1]);
                    if ($Passwd::Unix::Alt::errstr) {
                        $err = "Can't add user to group $gi: ".
                            $Passwd::Unix::Alt::errstr;
                        goto CHECK_ERR;
                    }
                }
            }

            if ($create_home_dir) {
                $log->tracef("Creating home dir %s ...", $new_home_dir);
                my %s_args = (path=>$new_home_dir, mode=>$new_home_dir_mode,
                              should_exist=>1);
                unless ($>) {
                    $s_args{owner} = $uid;
                    $s_args{group} = $gid;
                }
                my $res = setup_dir(%s_args, -undo_action=>"do",
                                    -undo_hint=>{tmp_dir=>$tmp_dir});
                if ($res->[0] != 200 && $res->[0] != 304) {
                    $err = "Can't create home dir: $res->[0] - $res->[1]";
                    goto CHECK_ERR;
                }
                unshift @$undo_steps,
                    ["unsetup_dir", \%s_args, $res->[3]{undo_data}]
                        unless $res->[0] == 304;
            }
            if ($create_home_dir && $use_skel_dir) {
                my $old_cwd = $CWD;
                if (!(-d $skel_dir)) {
                    $log->warnf("skel dir %s doesn't exist, ".
                                    "skipped copying files", $skel_dir);
                } elsif (!(eval { $CWD = $skel_dir })) {
                    $log->warnf("Can't chdir to skel dir %s, skipped");
                } else {
                    $log->tracef("Copying files from skeleton %s ...",
                                 $skel_dir);
                    # XXX currently all file/dir created default mode (755/644)
                    # XXX doesn't handle symlink yet
                    find(
                        sub {
                            return if $_ eq '.' || $_ eq '..';
                            my $d = $File::Find::dir;
                            $d =~ s!^\./?!!;
                            my $p = (length($d) ? "$d/" : "").$_;
                            $log->tracef("skel: %s", $p); # TMP
                            my %s_args = (path=>"$new_home_dir/$p",
                                          should_exist=>1);
                            my $res;
                            if (-d $_) {
                                $res = setup_dir(
                                    %s_args, -undo_action=>"do",
                                    -undo_hint=>{tmp_dir=>$tmp_dir});
                                # ignore error
                                if ($res->[0] == 200) {
                                    unshift @$undo_steps,
                                        ["unsetup_dir",
                                         \%s_args, $res->[3]{undo_data}];
                                }
                            } else {
                                my $content = read_file($_, err_mode=>'quiet');
                                $res = setup_file(
                                    %s_args, -undo_action=>"do",
                                    gen_content_code=>sub {$content},
                                    -undo_hint=>{tmp_dir=>$tmp_dir});
                                # ignore error
                                if ($res->[0] == 200) {
                                    unshift @$undo_steps,
                                        ["unsetup_file",
                                         \%s_args, $res->[3]{undo_data},
                                         $content];
                                }
                            }
                        }, "."
                    );
                    $CWD = $old_cwd;
                } # if copy skel
            } # if create home dir

        } elsif ($step->[0] eq 'delete') { # arg: -

            $pu->del($name);
            if ($Passwd::Unix::Alt::errstr) {
                $err = $Passwd::Unix::Alt::errstr;
            } else {
                unshift @$undo_steps, ['create', @{$step}[1..@$step-1]];
            }

        } elsif ($step->[0] eq 'add_group') { # arg: group name

            my $gi = $step->[1];
            my @g = $pu->group($gi); # XXX check error
            unless ($g[0]) {
                $log->warn("group $gi doesn't exist, skipped");
                next STEP;
            }
            if ($name ~~ @{$g[1]}) {
                # user already member of this group
                next STEP;
            }
            $log->trace("Adding $name to group $gi ...");
            push @{$g[1]}, $name;
            $pu->group($gi, $g[0], $g[1]);
            if ($Passwd::Unix::Alt::errstr) {
                $err = "Can't add user to group $gi: ".
                    $Passwd::Unix::Alt::errstr;
                goto CHECK_ERR;
            }
            unshift @$undo_steps, ["remove_group", $gi];

        } elsif ($step->[0] eq 'remove_group') { # arg: group name

            my $gi = $step->[1];
            my @g = $pu->group($gi); # XXX check error
            unless ($g[0]) {
                $log->warn("group $gi doesn't exist, skipped");
                next STEP;
            }
            unless ($name ~~ @{$g[1]}) {
                # user already not member of this group
                next STEP;
            }
            $log->trace("Removing $name from group $i ...");
            $g[1] = [grep {$_ ne $name} @{$g[1]}];
            $pu->group($gi, $g[0], $g[1]);
            if ($Passwd::Unix::Alt::errstr) {
                $err = "Can't add user to group $gi: ".
                    $Passwd::Unix::Alt::errstr;
                goto CHECK_ERR;
            }
            unshift @$undo_steps, ["add_group", $gi];

        } elsif ($step->[0] =~ /^(un)?(setup_(?:dir|file|unix_group))$/) {

            my ($is_undo, $f) = ($1, $2);
            my %s_args = %{$step->[1]};
            my %a_args = ();
            if ($f eq 'setup_file') {
                # can't serialize coderef, so we carry around content
                $a_args{gen_content_code} = sub { $step->[3] };
            }
            $a_args{-undo_action} = $is_undo ? "undo" : "do";
            $a_args{-undo_data}   = $step->[2];
            $a_args{-undo_hint}   = {tmp_dir=>$tmp_dir};
            no strict 'refs';
            my $res = $f->(%s_args, %a_args);
            if ($res->[0] == 200) {
                unshift @$undo_steps, [
                    ($is_undo ? "" : "un").$f,
                    \%s_args,
                    $res->[3]{undo_data},
                    $f eq 'setup_file' ? $step->[3] : undef,
                ];
            } elsif ($res->[0] == 304) {
                # nothing was done, success, no undo
            } else {
                # ignore setup_dir errors
                if ($f eq 'setup_dir') {
                    $log->warn("Can't successfully run $step->[0]: ".
                                   "$res->[0] - $res->[1], ignored");
                } else {
                    $err = "Error result from $f: $res->[0] - $res->[1]";
                }
            }

}

my $res = gen_undoable_func(
    name => 'setup_unix_ser',
    summary  => "Setup Unix user (existence, group memberships)",
    description => <<'_',

On do, will create Unix user if not already exists. And also make sure user
belong to specified groups (and not belong to unwanted groups). Return the
created UID/GID in the result.

On undo, will delete Unix user (along with its initially created home dir and
files) if it was created by this function. Also will restore old group
memberships.

_
    trash_dir   => 1,
    args => {
        name => {
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
            schema  => ['int' => {default=>0}],
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

    check_args => sub {
        my $args = shift;

        $args->{name} or return [400, "Please specify name"];
        $args->{name} =~ /^[A-Za-z0-9_-]+$/
            or return [400, "Invalid user name syntax"];
        $args->{new_password}      //= _rand_pass();
        $args->{new_gecos}         //= "";
        $args->{new_home_dir}      //= "/home/$args->{name}";
        $args->{new_home_dir_mode} //= 0700;
        $args->{new_shell}         //= "/bin/bash";
        $args->{create_home_dir}   //= 1;
        $args->{use_skel_dir}      //= 1;
        $args->{skel_dir}          //= "/etc/skel";
        $args->{primary_group}     //= $args->{name};
        $args->{member_of}         //= [];
        push @{$args->{member_of}}, $args->{primary_group}
            unless $args->{primary_group} ~~ @{$args->{member_of}};
        $args->{not_member_of}     //= [];
        for (@{$args->{member_of}}) {
            return [400, "Group $_ is in member_of and not_member_of"]
                if $_ ~~ @{$args->{not_member_of}};
        }
        [200, "OK"];
    },

    build_steps => sub {
        my $args = shift;
        my $name = $args->{name};

        my $pu = _create_pu_object($args);
        my @steps;

        if ($args->{primary_group} eq $name) {
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

    steps => {
        create => {
            summary => 'Create user',
            check_or_fix => \&_check_or_fix,
        },
        delete => {
            summary => 'Delete user',
            check_or_fix => \&_check_or_fix,
        },
        add_group => {
            summary => 'Add user to a group',
            check_or_fix => \&_check_or_fix,
        },
        remove_group => {
            summary => 'Remove user from a group',
            check_or_fix => \&_check_or_fix,
        },
    },
);
die "Can't generate function: $res->[0] - $res->[1]" unless $res->[0] == 200;

} else {

            die "BUG: Unknown step command: $step->[0]";

        }
      CHECK_ERR:
        if ($err) {
            if ($rollback) {
                die "Failed rollback step $i of 0..".(@$steps-1).": $err";
            } else {
                $log->tracef("Step failed: $err, performing rollback (%s)...",
                             $undo_steps);
                $rollback = $err;
                $steps = $undo_steps;
                goto STEP; # perform steps all over again
            }
        }
    }
    return [500, "Error (rollbacked): $rollback"] if $rollback;

    my $data = {uid=>$uid, gid=>$gid};
    my $meta = {};
    $meta->{undo_data} = $undo_steps if $save_undo;
    $log->tracef("meta: %s", $meta);
    return [@$steps ? 200 : 304, @$steps ? "OK" : "Nothing done", $data, $meta];
}

1;
# ABSTRACT: Setup Unix user (existence, home dir, group memberships)
__END__

=head1 SYNOPSIS

 use Setup::Unix::User 'setup_unix_user';

 # simple usage (doesn't save undo data)
 my $res = setup_unix_user name => 'foo',
                           member_of => ['admin', 'wheel'];
 die unless $res->[0] == 200 || $res->[0] == 304;

 # perform setup and save undo data (undo data should be serializable)
 $res = setup_unix_user ..., -undo_action => 'do';
 die unless $res->[0] == 200 || $res->[0] == 304;
 my $undo_data = $res->[3]{undo_data};

 # perform undo
 $res = setup_unix_user ..., -undo_action => "undo", -undo_data=>$undo_data;
 die unless $res->[0] == 200 || $res->[0] == 304;


=head1 DESCRIPTION

This module provides one function: B<setup_unix_user>.

This module is part of the L<Setup> modules family.

This module uses L<Log::Any> logging framework.

This module has L<Rinci> metadata.


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

L<Setup::Unix::Group>.

L<Setup>.

=cut
