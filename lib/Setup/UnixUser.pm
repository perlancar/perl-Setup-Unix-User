package Setup::UnixUser;
# ABSTRACT: Make sure a Unix user exists

use 5.010;
use strict;
use warnings;
use Log::Any '$log';

use Setup::UnixGroup qw(setup_unix_group);
use Setup::File      qw(setup_file);
use Setup::Dir       qw(setup_dir);

require Exporter;
our @ISA       = qw(Exporter);
our @EXPORT_OK = qw(setup_unix_user);

our %SPEC;

$SPEC{setup_unix_user} = {
    summary  => "Make sure a Unix user exists",
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
        # most unix systems use shadow nowadays anyway
        #new_password => ['str' => {
        #    summary => 'Set password when creating new user',
        #}],
        new_gecos => ['str' => {
            summary => 'Set gecos (usually, full name) when creating '.
                'new user, defaults to <username>',
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
    my $dry_run        = $args{-dry_run};
    my $undo_action    = $args{-undo_action} // "";

    # check args
    my $name           = $args{name};
    $log->trace('=> setup_unix_group(name=$name)');
    $name or return [400, "Please specify name"];
    $name =~ /^[A-Za-z0-9_-]+$/ or return [400, "Invalid group name syntax"];

    # create object
    my $res            = _create_unixu_object(
        $dry_run,
        $args{_group_file_path});
    return $res unless $res->[0] == 200;
    my $unixg          = $res->[2];
    #$log->tracef("unix group object: %s", $unixg);

    # check current state
    my @g              = $unixg->group($name);
    my $exists         = $g[0] ? 1:0;
    my $state_ok       = 1;
    if (!$exists) {
        $log->tracef("nok: unix group $name doesn't exist");
        $state_ok = 0;
    }

    if ($undo_action eq 'undo') {
        return [412, "Can't undo: group doesn't exist"]
            unless $state_ok;
        return [304, "dry run"] if $dry_run;
        my $undo_data = $args{-undo_data};
        my $res = _undo(\%args, $undo_data, 0, $unixg);
        if ($res->[0] == 200) {
            return [200, "OK", undef, {redo_data=>$res->[2]}];
        } else {
            return $res;
        }
    } elsif ($undo_action eq 'redo') {
        return [412, "Can't redo: group already exists"]
            if $state_ok;
        return [304, "dry run"] if $dry_run;
        my $redo_data = $args{-redo_data};
        my $res = _redo(\%args, $redo_data, 0, $unixg);
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

    $log->debug("fix: creating Unix group $name ...");

    $log->trace("finding an unused GID ...");
    my @gids = map {($unixg->group($_))[1]} $unixg->groups;
    #$log->tracef("gids = %s", \@gids);
    my $gid = $args{min_new_gid} // 1;
    while (1) { last unless $gid ~~ @gids; $gid++ }

    $unixg->group($name, "x", $gid);
    $unixg->commit;
    push @undo, ["delete", $gid];

    my $meta = {};
    $meta->{undo_data} = \@undo if $save_undo;
    [200, "OK", {gid=>$gid}, $meta];
}

sub _undo_or_redo {
    my ($which, $args, $undo_data, $is_rollback, $unixg) = @_;
    die "BUG: which must be undo or redo"
        unless $which && $which =~ /^(undo|redo)$/;
    die "BUG: Unix::GroupFile object not supplied" unless $unixg;
    return [200, "Nothing to do"] unless defined($undo_data);
    die "BUG: Invalid undo data, must be arrayref"
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
            $unixg->delete($name);
            $unixg->commit;
            push @redo_data, ['create', $arg[0]];
        } elsif ($cmd eq 'create') {
            $unixg->group($name, "x", $arg[0]);
            $unixg->commit;
            push @redo_data, ['delete', $arg[0]];
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
