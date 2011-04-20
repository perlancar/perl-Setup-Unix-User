package Setup::UnixGroup;
# ABSTRACT: Make sure a Unix group exists

use 5.010;
use strict;
use warnings;
use Log::Any '$log';

require Exporter;
our @ISA       = qw(Exporter);
our @EXPORT_OK = qw(setup_unix_group);

use Passwd::Unix;

our %SPEC;

$SPEC{setup_unix_group} = {
    summary  => "Makes sure a Unix group exists",
    description => <<'_',

On do, will create Unix group if not already exists.

On undo, will delete Unix group previously created. On redo, will recreate Unix
group with the same GID.

_
    args => {
        name => ['str*' => {
            summary => 'Group name',
        }],
        min_new_gid => ['int' => {
            summary => 'When creating new group, specify minimum GID',
            default => 1,
        }],
    },
    features => {undo=>1, dry_run=>1},
};
sub setup_unix_group {
    my %args           = @_;
    my $dry_run        = $args{-dry_run};
    my $undo_action    = $args{-undo_action} // "";

    # check args
    my $name           = $args{name};
    $log->trace('=> setup_unix_group(name=$name)');
    $name or return [400, "Please specify name"];
    $name =~ /^[A-Za-z0-9_-]+$/ or return [400, "Invalid group name syntax"];

    # create object
    my $group_path   = $args{_group_path}   // "/etc/group";
    my $gshadow_path = $args{_gshadow_path} // "/etc/gshadow";
    my $pu = Passwd::Unix->new(
        group    => $group_path,
        gshadow  => $gshadow_path,
        warnings => 1,
    );

    # check current state
    my @g              = $pu->group($name);
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
        my $res = _undo(\%args, $undo_data, 0, $pu);
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

    $log->debug("fix: creating Unix group $name ...");

    $log->trace("finding an unused GID ...");
    my @gids = map {($pu->group($_))[0]} $pu->groups;
    #$log->tracef("gids = %s", \@gids);
    my $gid = $args{min_new_gid} // 1;
    while (1) { last unless $gid ~~ @gids; $gid++ }

    unless ($pu->group($name, $gid, [])) {
        _undo(\%args, \@undo, 1, $pu);
        return [500, "Can't add group to $group_path"];
    }
    push @undo, ["delete", $gid];

    my $meta = {};
    $meta->{undo_data} = \@undo if $save_undo;
    [200, "OK", {gid=>$gid}, $meta];
}

sub _undo_or_redo {
    my ($which, $args, $undo_data, $is_rollback, $pu) = @_;
    die "BUG: which must be undo or redo"
        unless $which && $which =~ /^(undo|redo)$/;
    die "BUG: Passwd::Unix object not supplied" unless $pu;
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
            if ($pu->del_group($name)) {
                push @redo_data, ['create', $arg[0]];
            } else {
                $err = "failed";
            }
        } elsif ($cmd eq 'create') {
            if ($pu->group($name, $arg[0], [])) {
                push @redo_data, ['delete', $arg[0]];
            } else {
                $err = "failed";
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
