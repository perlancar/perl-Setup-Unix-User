package Setup::Unix::Group;

use 5.010;
use strict;
use warnings;
use Log::Any '$log';

require Exporter;
our @ISA       = qw(Exporter);
our @EXPORT_OK = qw(setup_unix_group);

use Unix::Passwd::File;

# VERSION

our %SPEC;

my %common_args = (
    etc_dir => {
        summary => 'Location of passwd files',
        schema  => ['str*' => {default=>'/etc'}],
    },
    group => {
        schema  => 'str*',
        summary => 'Group name',
    },
);

$SPEC{delgroup} = {
    v => 1.1,
    summary => 'Delete group',
    args => {
        %common_args,
    },
    features => {
        tx => {v=>2},
        idempotent => 1,
    },
};
sub delgroup {
    my %args = @_;

    my $tx_action = $args{-tx_action} // '';
    my $group     = $args{group} or return [400, "Please specify name"];
    $group =~ $Unix::Passwd::File::re_group
        or return [400, "Invalid group"];
    my %ca        = (etc_dir => $args{etc_dir}, group=>$group);

    my $res = Unix::Passwd::File::get_group(%ca);
    return $res unless $res->[0] == 200 || $res->[0] == 404;

    return [304, "Group doesn't exist"] if $res->[0] == 404;

    my @undo;

    if ($tx_action eq 'check_state') {
        return [200, "Fixable", undef, {undo_actions=>[
            [addgroup => {%ca, gid => $res->[2]{gid}}],
        ]}];
    } elsif ($tx_action eq 'fix_state') {
        $log->infof("Deleting Unix group %s ...", $group);
        return Unix::Passwd::File::delete_group(%ca);
    }
    [400, "Invalid -tx_action"];
}

$SPEC{addgroup} = {
    v => 1.1,
    summary => 'Add group',
    args => {
        %common_args,
        gid => {
            summary => 'Add with specified GID',
            description => <<'_',

If not specified, will search an unused GID from `min_new_gid` to `max_new_gid`.

_
            schema => 'int',
        },
        min_new_gid => {
            schema => [int => {default=>1000}],
        },
        max_new_gid => {
            schema => [int => {default=>65535}],
        },
    },
    features => {
        tx => {v=>2},
        idempotent => 1,
    },
};
sub addgroup {
    my %args = @_;

    my $tx_action = $args{-tx_action} // '';
    my $group     = $args{group} or return [400, "Please specify name"];
    $group =~ $Unix::Passwd::File::re_group
        or return [400, "Invalid group"];
    my $gid       = $args{gid};
    my %ca0       = (etc_dir => $args{etc_dir});
    my %ca        = (%ca0, group=>$group);

    my $res = Unix::Passwd::File::get_group(%ca);
    $log->errorf("result of get_group: %s", $res);
    return $res unless $res->[0] == 200 || $res->[0] == 404;

    if ($res->[0] == 200) {
        if (!defined($gid) || $gid == $res->[2]{gid}) {
            return [304, "Group already exists"];
        } else {
            return [412, "Group already exists but with different GID ".
                        "($res->[2]{gid}, wanted $gid)"];
        }
    } else {
        my $found = defined($gid);
        if (!$found) {
            $res = Unix::Passwd::File::list_groups(%ca0, detail=>1);
            return $res unless $res->[0] == 200;
            my @gids = map {$_->{gid}} @{$res->[2]};
            #$log->tracef("gids = %s", \@gids);
            my $max;
            # we shall search a range for a free gid
            $gid = $args{min_new_gid} //  1000;
            $max = $args{max_new_gid} // 65535;
            $log->tracef("finding an unused GID from %d to %d ...", $gid, $max);
            while (1) {
                last if $gid > $max;
                unless ($gid ~~ @gids) {
                    #$log->tracef("found unused GID: %d", $gid);
                    $found++;
                    last;
                }
                $gid++;
            }
            return [412, "Can't find unused GID"] unless $found;
        }
    }

    if ($tx_action eq 'check_state') {
        return [200, "Fixable", undef, {undo_actions=>[
            [delgroup => {%ca, gid=>$gid}],
        ]}];
    } elsif ($tx_action eq 'fix_state') {
        $log->infof("Adding Unix group %s ...", $group);
        $res = Unix::Passwd::File::add_group(%ca, gid=>$gid);
        if ($res->[0] == 200) {
            $args{-stash}{result}{gid} = $gid;
            return [200, "Created"];
        } else {
            return $res;
        }
    }
    [400, "Invalid -tx_action"];
}

$SPEC{setup_unix_group} = {
    v           => 1.1,
    summary     => "Setup Unix group (existence)",
    description => <<'_',

On do, will create Unix group if not already exists. The created GID will be
returned in the result (`{gid => GID}`).

On undo, will delete Unix group previously created.

On redo, will recreate the Unix group with the same GID.

_
    args => $SPEC{adduser}{args},
    features => {
        tx => {v=>2},
        idempotent => 1,
    },
};
sub setup_unix_group {
    addgroup(@_);
}

1;
# ABSTRACT: Setup Unix group (existence)

=head1 FAQ

=head2 How to create group with a specific GID?

Set C<min_new_gid> and C<max_new_gid> to your desired value. Note that the
function will report failure if when wanting to create a group, the desired GID
is already taken. But the function will not report failure if the group already
exists, even with a different GID.


=head1 SEE ALSO

L<Setup>

L<Setup::Unix::User>

=cut
