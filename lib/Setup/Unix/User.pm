package Setup::Unix::User;
# ABSTRACT: Ensure existence of Unix user and its group memberships

use 5.010;
use strict;
use warnings;
use Log::Any '$log';

use Setup::Unix::Group qw(setup_unix_group);
use Setup::File        qw(setup_file);
use Setup::Dir         qw(setup_dir);
use Text::Password::Pronounceable;

require Exporter;
our @ISA       = qw(Exporter);
our @EXPORT_OK = qw(setup_unix_user);

our %SPEC;

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

$SPEC{setup_unix_user} = {
    summary  => "Ensure existence of Unix user and its group memberships",
    description => <<'_',

On do, will create Unix user if not already exists.

Newly created user's group memberships, homedir and skeleton files can also be
created/copied automatically by this routine (utilizing Setup::Dir and
Setup::File).

On undo, will delete Unix user previously created (and/or remove/readd groups to
original state, remove homedirs, etc).

On redo, will recreate Unix user (and re-set memberships) with the same UID.

_
    args => {
        name => ['str*' => {
            summary => 'User name',
        }],
        member_of => ['array' => {
            summary => 'List of Unix group names that the user must be '.
                'member of',
            description => <<'_',

The first element will be used as the primary group. If a group doesn't exist,
it will be ignored.

If not specified, the default is one group having the same name as the user. The
group will be created if not already exists.

_
            of => 'str*',
        }],
        not_member_of => ['str*' => {
            summary => 'List of Unix group names that the user must NOT be '.
                'member of',
            of => 'str*',
        }],
        new_password => ['str' => {
            summary => 'Set password when creating new user',
            description => 'Default is a random password',
        }],
        new_gecos => ['str' => {
            summary => 'Set gecos (usually, full name) when creating new user',
            default => '',
        }],
        new_home_dir => ['str' => {
            summary => 'Set home directory when creating new user, '.
                'defaults to /home/<username>',
        }],
        new_home_dir_mode => [int => {
            summary => 'Set permission mode of home dir '.
                'when creating new user',
            default => 0700,
        }],
        new_shell => ['str' => {
            summary => 'Set shell when creating new user',
            default => '/bin/bash',
        }],
        skel_dir => [str => {
            summary => 'Directory to get skeleton files when creating new user',
            default => '/etc/skel',
        }],
        create_home_dir => [bool => {
            summary => 'Whether to create homedir when creating new user',
            default => 1,
        }],
        use_skel_dir => [bool => {
            summary => 'Whether to copy files from skeleton dir '.
                'when creating new user',
            default => 1,
        }],
    },
    features => {undo=>1, dry_run=>1},
};
sub setup_unix_user {
    my %args           = @_;
    $log->tracef("=> setup_unix_user(%s)", \%args);
    my $dry_run        = $args{-dry_run};
    my $undo_action    = $args{-undo_action} // "";

    # check args
    my $name           = $args{name};
    $name or return [400, "Please specify name"];
    $name =~ /^[A-Za-z0-9_-]+$/ or return [400, "Invalid group name syntax"];
    my $new_password      = $args{new_password}      // _rand_pass();
    my $new_gecos         = $args{new_gecos}         // "";
    my $new_home_dir      = $args{new_home_dir}      // "/home/$name";
    my $new_home_dir_mode = $args{new_home_dir_mode} // 0700;
    my $new_shell         = $args{new_shell}         // "/bin/bash";
    my $create_home_dir   = $args{create_home_dir}   // 1;
    my $use_skel_dir      = $args{use_skel_dir}      // 1;
    my $skel_dir          = $args{skel_dir}          // "/etc/skel";

    # create object
    my $passwd_path  = $args{_passwd_path}  // "/etc/passwd";
    my $group_path   = $args{_group_path}   // "/etc/group";
    my $shadow_path  = $args{_shadow_path}  // "/etc/shadow";
    my $gshadow_path = $args{_gshadow_path} // "/etc/gshadow";
    my $pu = Passwd::Unix::Alt->new(
        passwd   => $passwd_path,
        group    => $group_path,
        shadow   => $shadow_path,
        gshadow  => $gshadow_path,
        warnings => 0,
    );

    # check current state
    my @u              = $pu->user($name);
    my $exists         = @u ? 1:0;
    my $state_ok       = 1;
    my ($uid, $gid);
    my @membership;
    my $member_of      = $args{member_of} // [];
    push @$member_of, $name unless $name ~~ @$member_of;
    my $not_member_of  = $args{not_member_of} // [];
    {
        if (!$exists) {
            $log->tracef("nok: unix user $name doesn't exist");
            $state_ok = 0;
            last;
        }

        $uid = $u[1];
        $gid = $u[2];

        my @membership = _get_user_membership($name, $pu);
        for (@$member_of) {
            unless ($_ ~~ @membership) {
                $log->tracef("nok: should be member of $_ but isn't");
                $state_ok = 0;
            }
        }
        for (@$not_member_of) {
            if ($_ ~~ @membership) {
                $log->tracef("nok: should NOT be member of $_ but is");
                $state_ok = 0;
            }
        }
        last unless $state_ok;
    }

    if ($undo_action eq 'undo') {
        return [412, "Can't undo: user doesn't exist or has changed groups"]
            unless $state_ok;
        return [304, "dry run"] if $dry_run;
        my $undo_data = $args{-undo_data};
        my $res = _undo(\%args, $undo_data, 0, $pu);
        if ($res->[0] == 200) {
            return [200, "OK", undef, {redo_data=>$res->[2]}];
        } else {
            return $res;
        }
    } elsif ($undo_action eq 'redo') {
        return [412, "Can't redo: user already exists"]
            if $state_ok;
        return [304, "dry run"] if $dry_run;
        my $redo_data = $args{-redo_data};
        my $res = _redo(\%args, $redo_data, 0, $pu);
        if ($res->[0] == 200) {
            return [200, "OK", undef, {undo_data=>$res->[2]}];
        } else {
            return $res;
        }
    }

    my $save_undo = $undo_action ? 1:0;
    my @undo;
    return [304, "Already ok"] if $state_ok;
    return [304, "dry run"] if $dry_run;

    if (!$exists) {
        $log->trace("finding an unused UID ...");
        my @uids = map {($pu->user($_))[1]} $pu->users;
        $uid = $args{min_new_uid} // 1;
        while (1) { last unless $uid ~~ @uids; $uid++ }

        my @g = $pu->group($name);
        if ($g[0]) {
            $gid = $g[0];
        } else {
            $log->trace("fix: creating Unix group $name ...");
            my %g_args = (
                name => $name,
                _passwd_path => $passwd_path,
                _shadow_path => $shadow_path,
                _group_path => $group_path,
                _gshadow_path => $gshadow_path,
                min_new_gid => $uid,
                -undo_action => $save_undo ? 'do' : undef,
            );
            my $res = setup_unix_group(%g_args);
            #$log->tracef("res from setup_unix_group: %s", $res);
            if ($res->[0] != 200) {
                _undo(\%args, \@undo, 1, $pu);
                return [500, "Can't create Unix group: $res->[0] - $res->[1]"];
            } else {
                $gid = $res->[2]{gid};
                push @undo,
                    ["undo_setup_group", \%g_args, $res->[3]{undo_data}];
            }
        }

        $log->debug("fix: creating Unix user $name ...");
        $pu->user($name, $pu->encpass($new_password), $uid, $gid, $new_gecos,
                  $new_home_dir, $new_shell);
        if ($Passwd::Unix::Alt::errstr) {
            my $e = $Passwd::Unix::Alt::errstr; # avoid being reset by _undo
            _undo(\%args, \@undo, 1, $pu);
            return [500, "Can't create Unix user: $e"];
        } else {
            push @undo, ["delete", $new_password, $uid, $gid, $new_gecos,
                         $new_home_dir, $new_shell];
        }

        $exists = 1;
        @membership = ($name);

        if ($create_home_dir) {
            $log->debugf("fix: creating home dir %s ...", $new_home_dir);
            # XXX

            if ($use_skel_dir) {
                $log->debugf("fix: copying files from skeleton %s ...",
                             $skel_dir);
                # XXX
            }
        }

    }

    if (!$state_ok) {
        $log->tracef("fix: membership (current membership: %s, ".
                         "must be member of: %s, must not be member of: %s)",
                     \@membership, $member_of, $not_member_of
                 );
        for my $i (@$member_of) {
            my @g = $pu->group($i);
            unless ($g[0]) {
                $log->warn("group $i doesn't exist, skipped");
                next;
            }
            unless ($i ~~ @membership) {
                $log->trace("fix: adding $name to group $i ...");
                unless ($name ~~ @{$g[1]}) {
                    push @{$g[1]}, $name;
                    $pu->group($i, $g[0], $g[1]);
                    if ($Passwd::Unix::Alt::errstr) {
                        my $e = $Passwd::Unix::Alt::errstr;
                        _undo(\%args, \@undo, 1, $pu);
                        return [500, "Can't add user to group $i: $e"];
                    }
                    push @undo, ["rm_from_group", $i];
                }
            }
        }
        for my $i (@$not_member_of) {
            my @g = $pu->group($i);
            unless ($g[0]) {
                $log->warn("group $i doesn't exist, skipped");
                next;
            }
            if ($i ~~ @membership) {
                $log->trace("fix: removing $name from group $i ...");
                if ($name ~~ @{$g[1]}) {
                    $g[1] = [grep {$_ ne $name} @{$g[1]}];
                    $pu->group($i, $g[0], $g[1]);
                    if ($Passwd::Unix::Alt::errstr) {
                        my $e = $Passwd::Unix::Alt::errstr;
                        _undo(\%args, \@undo, 1, $pu);
                        return [500, "Can't remove user from group $i: $e"];
                    }
                    push @undo, ["add_to_group", $i];
                }
            }
        }
    }

    my $meta = {};
    $meta->{undo_data} = \@undo if $save_undo;
    [200, "OK", {uid=>$uid, gid=>$gid}, $meta];
}

sub _undo_or_redo {
    my ($which, $args, $undo_data, $is_rollback, $pu) = @_;
    $log->tracef("Performing %s for setup_unix_user ...",
                 $is_rollback ? "rollback" : "undo");
    die "BUG: which must be undo or redo"
        unless $which && $which =~ /^(undo|redo)$/;
    die "BUG: Passwd::Unix::Alt object not supplied" unless $pu;
    return [200, "Nothing to do"] unless defined($undo_data);
    die "BUG: Invalid $which data, must be arrayref"
        unless ref($undo_data) eq 'ARRAY';

    my $name = $args->{name};

    my $i = 0;
    my @redo_data;
    for my $undo_step (reverse @$undo_data) {
        $log->tracef("${which}[%d of 0..%d]: %s",
                     $i, scalar(@$undo_data)-1, $undo_step);
        die "BUG: Invalid ${which}_step[$i], must be arrayref"
            unless ref($undo_step) eq 'ARRAY';
        my ($cmd, @arg) = @$undo_step;
        my $err;
        if ($cmd eq 'delete') {
            $pu->del($name);
            if ($Passwd::Unix::Alt::errstr) {
                $err = $Passwd::Unix::Alt::errstr;
            } else {
                push @redo_data, ['create', @arg];
            }
        } elsif ($cmd eq 'create') {
            $pu->user($name, $pu->encpass($arg[0]), @arg[1..5]);
            push @redo_data, ['delete', @arg];
        } elsif ($cmd =~ /^(undo_)?(setup_group|XXX)$/) {
            my ($is_undo, $subname) = ($1, $2);
            my $subref;
            if ($subname eq 'setup_group') {
                $subref = \&setup_unix_group;
            }
            if ($is_undo) {
                my $res = $subref->(%{$arg[0]},
                                    -undo_action => "undo",
                                    -undo_data   => $arg[1]);
                if ($res->[0] !~ /^(200|304|412)$/) {
                    $err = "$res->[0] - $res->[1]";
                } else {
                    push @redo_data, [$subname, $arg[0], $res->[3]{redo_data}];
                }
            } else {
                my $res = $subref->(%{$arg[0]},
                                    -undo_action => "redo",
                                    -redo_data   => $arg[1]);
                if ($res->[0] !~ /^(200|304|412)$/) {
                    $err = "$res->[0] - $res->[1]";
                } else {
                    push @redo_data, ["undo_$subname",
                                      $arg[0], $res->[3]{redo_data}];
                }
            }
        } else {
            die "BUG: Invalid ${which}_step[$i], unknown command: $cmd";
        }
        if ($err) {
            if ($is_rollback) {
                die "Can't rollback ${which} step[$i] ($cmd): $err";
            } else {
                return [500, "Can't ${which} step[$i] ($cmd): $err"];
            }
        }
        $i++;
    }
    [200, "OK", \@redo_data];
}

sub _undo { _undo_or_redo('undo', @_) }
sub _redo { _undo_or_redo('redo', @_) }

1;
__END__

=head1 SYNOPSIS

 use Setup::Unix::User 'setup_unix_user';

 # simple usage (doesn't save undo data)
 my $res = setup_unix_user name => 'foo',
                           members_of => ['admin', 'wheel'];
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

This module is part of the Setup modules family.

This module uses L<Log::Any> logging framework.

This module's functions have L<Sub::Spec> specs.


=head1 THE SETUP MODULES FAMILY

I use the C<Setup::> namespace for the Setup modules family, typically used in
installers (or other applications). See L<Setup::File::Symlink> for more details
about the Setup modules family.


=head1 FUNCTIONS

None are exported by default, but they are exportable.


=head1 SEE ALSO

L<Setup::Unix::Group>.

L<Sub::Spec>, specifically L<Sub::Spec::Clause::features> on dry-run/undo.

Other modules in Setup:: namespace.

=cut
