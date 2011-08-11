package Setup::Unix::Group;

use 5.010;
use strict;
use warnings;
use Log::Any '$log';

require Exporter;
our @ISA       = qw(Exporter);
our @EXPORT_OK = qw(setup_unix_group);

use Passwd::Unix::Alt;

# VERSION

our %SPEC;

$SPEC{setup_unix_group} = {
    summary  => "Setup Unix group (existence)",
    description => <<'_',

On do, will create Unix group if not already exists.

On undo, will delete Unix group previously created.

On redo, will recreate the Unix group with the same GID.

_
    args => {
        name => ['str*' => {
            summary => 'Group name',
        }],
        min_new_gid => ['int' => {
            summary => 'When creating new group, specify minimum GID',
            default => 0,
        }],
        min_new_gid => ['int' => {
            summary => 'When creating new group, specify maximum GID',
            default => 65534,
        }],
        new_gid => ['int' => {
            summary => 'Specify desired GID',
            description => <<'_',

This is equivalent to specifying min_new_gid=gid and max_new_gid=gid.

_
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
    $name or return [400, "Please specify name"];
    $name =~ /^[A-Za-z0-9_-]+$/ or return [400, "Invalid group name syntax"];

    # create PUA object
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

    my $gid;

    # collect steps
    my $steps;
    if ($undo_action eq 'undo') {
        $steps = $args{-undo_data} or return [400, "Please supply -undo_data"];
    } else {
        $steps = [];
        {
            my @g = $pu->group($name);
            return [500, "Can't get Unix group: $Passwd::Unix::Alt::errstr"]
                if $Passwd::Unix::Alt::errstr &&
                    $Passwd::Unix::Alt::errstr !~ /unknown group/i;
            if (!$g[0]) {
                $log->info("nok: unix group $name doesn't exist");
                push @$steps, ["create"];
                last;
            }
        }
    }

    return [400, "Invalid steps, must be an array"]
        unless $steps && ref($steps) eq 'ARRAY';
    return [200, "Dry run"] if $dry_run && @$steps;

    my $save_undo = $undo_action ? 1:0;

    # perform the steps
    my $rollback;
    my $undo_steps = [];
  STEP:
    for my $i (0..@$steps-1) {
        my $step = $steps->[$i];
        $log->tracef("step %d of 0..%d: %s", $i, @$steps-1, $step);
        my $err;
        return [400, "Invalid step (not array)"] unless ref($step) eq 'ARRAY';

        my @g = $pu->group($name);
        if ($Passwd::Unix::Alt::errstr &&
                $Passwd::Unix::Alt::errstr !~ /unknown group/i) {
            $err = "Can't check group entry: $Passwd::Unix::Alt::errstr";
            goto CHECK_ERR;
        }
        if ($step->[0] eq 'create') {
            $gid = $step->[1];
            if ($g[0]) {
                if (!defined($gid)) {
                    # group already exists, skip step
                    next STEP;
                } elsif ($gid ne $g[0]) {
                    $err = "Group already exists but with different GID $g[0]".
                        " (we need to create GID $g[0])";
                }
            } else {
                my $found = defined($gid);
                if (!$found) {
                    $log->trace("finding an unused GID ...");
                    my @gids = map {($pu->group($_))[0]} $pu->groups;
                    #$log->tracef("gids = %s", \@gids);
                    my $max;
                    # we shall search a range for a free gid
                    if (defined $args{new_gid}) {
                        $gid = $args{new_gid};
                        $max = $args{new_gid};
                    } else {
                        $gid = $args{min_new_gid} // 1;
                        $max = $args{max_new_gid} // 65535;
                    }
                    while (1) {
                        last if $gid > $max;
                        unless ($gid ~~ @gids) {
                            $log->tracef("found unused GID: %d", $gid);
                            $found++;
                            last;
                        }
                        $gid++;
                    }
                }
                if (!$found) {
                    $err = "Can't find unused GID";
                    goto CHECK_ERR;
                }
                $pu->group($name, $gid, []);
                if ($Passwd::Unix::Alt::errstr) {
                    $err = "Can't add group entry in $group_path: ".
                        "$Passwd::Unix::Alt::errstr";
                } else {
                    unshift @$undo_steps, ["delete", $gid];
                }
            }
        } elsif ($step->[0] eq 'delete') {
            if (!$g[0]) {
                # group doesn't exist, skip this step
                next STEP;
            }
            $pu->del_group($name);
            if ($Passwd::Unix::Alt::errstr) {
                $err = $Passwd::Unix::Alt::errstr;
            } else {
                unshift @$undo_steps, ['create', $g[0]];
            }
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

    my $data = {gid=>$gid};
    my $meta = {};
    $meta->{undo_data} = $undo_steps if $save_undo;
    $log->tracef("meta: %s", $meta);
    return [@$steps ? 200 : 304, @$steps ? "OK" : "Nothing done", $data, $meta];
}
1;
# ABSTRACT: Setup Unix group (existence)
__END__

=head1 SYNOPSIS

 use Setup::Unix::Group 'setup_unix_group';

 # simple usage (doesn't save undo data)
 my $res = setup_unix_group name => 'foo';
 die unless $res->[0] == 200 || $res->[0] == 304;

 # perform setup and save undo data (undo data should be serializable)
 $res = setup_unix_group ..., -undo_action => 'do';
 die unless $res->[0] == 200 || $res->[0] == 304;
 my $undo_data = $res->[3]{undo_data};

 # perform undo
 $res = setup_unix_group ..., -undo_action => "undo", -undo_data=>$undo_data;
 die unless $res->[0] == 200 || $res->[0] == 304;


=head1 DESCRIPTION

This module provides one function: B<setup_unix_group>.

This module is part of the Setup modules family.

This module uses L<Log::Any> logging framework.

This module's functions have L<Sub::Spec> specs.


=head1 THE SETUP MODULES FAMILY

I use the C<Setup::> namespace for the Setup modules family. See L<Setup::File>
for more details on the goals, characteristics, and implementation of Setup
modules family.


=head1 FUNCTIONS

None are exported by default, but they are exportable.


=head1 SEE ALSO

L<Setup::Unix::User>.

Other modules in Setup:: namespace.

=cut
