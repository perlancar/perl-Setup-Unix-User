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

sub _create_pu_object {
    my %args = @_;

    my $passwd_path  = $args{passwd_path}  // "/etc/passwd";
    my $group_path   = $args{group_path}   // "/etc/group";
    my $shadow_path  = $args{shadow_path}  // "/etc/shadow";
    my $gshadow_path = $args{gshadow_path} // "/etc/gshadow";
    my $pu = Passwd::Unix::Alt->new(
        passwd   => $passwd_path,
        group    => $group_path,
        shadow   => $shadow_path,
        gshadow  => $gshadow_path,
        warnings => 0,
        #lock     => 1,
    );
    if (wantarray) {
        return ($pu, $passwd_path, $group_path, $shadow_path, $gshadow_path);
    } else {
        return $pu;
    }
}

my %common_args = (
    passwd_path => {
        summary => 'Path to passwd file',
        schema  => ['str*' => {default=>'/etc/passwd'}],
    },
    shadow_path => {
        summary => 'Path to shadow file',
        schema  => ['str*' => {default=>'/etc/shadow'}],
    },
    gpasswd_path => {
        summary => 'Path to gpasswd file',
        schema  => ['str*' => {default=>'/etc/gpasswd'}],
    },
    gshadow_path => {
        summary => 'Path to gshadow file',
        schema  => ['str*' => {default=>'/etc/gshadow'}],
    },
    name => {
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
    my $name      = $args{name} or return [400, "Please specify name"];
    $name=~ /\A[A-Za-z0-9_-]+\z/
        or return [400, "Invalid group name syntax"];
    my $pu        = _create_pu_object(%args);

    my %aargs = map {$_=>$args{$_}}
        grep {/(passwd|group|g?shadow)_path/ && defined($args{$_})} %args;

    my @g = $pu->group($name);
    if ($Passwd::Unix::Alt::errstr &&
            $Passwd::Unix::Alt::errstr !~ /unknown group/i) {
        return [500, "Can't check group entry: $Passwd::Unix::Alt::errstr"];
    }

    my @undo;

    return [304, "Group doesn't exist"] unless $g[0];

    if ($tx_action eq 'check_state') {
        return [200, "Fixable", undef, {undo_actions=>[
            [addgroup => {%aargs, name=>$name, gid=>$g[0]}]]}];
    } elsif ($tx_action eq 'fix_state') {
        $log->infof("Deleting Unix group %s ...", $name);
        $pu->del_group($name);
        if ($Passwd::Unix::Alt::errstr) {
            return [500, "Can't delete group: $Passwd::Unix::Alt::errstr"];
        }
        return [200, "Deleted"];
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
            schema => [int => {default=>0}],
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
    my $name      = $args{name} or return [400, "Please specify name"];
    $name=~ /\A[A-Za-z0-9_-]+\z/
        or return [400, "Invalid group name syntax"];
    my $gid       = $args{gid};
    my $pu        = _create_pu_object(%args);

    my %aargs = map {$_=>$args{$_}}
        grep {/(passwd|group|g?shadow)_path/ && defined($args{$_})} %args;

    my @g = $pu->group($name);
    if ($Passwd::Unix::Alt::errstr &&
            $Passwd::Unix::Alt::errstr !~ /unknown group/i) {
        return [500, "Can't check group entry: $Passwd::Unix::Alt::errstr"];
    }

    if ($g[0]) {
        if (!defined($gid)) {
            return [304, "Group already exists"];
        } elsif ($gid ne $g[0]) {
            return [412, "Group already exists but with different GID ".
                        "($g[0], wanted $gid)"];
        }
    } else {
        my $found = defined($gid);
        if (!$found) {
            my @gids = map {($pu->group($_))[0]} $pu->groups;
            $log->tracef("gids = %s", \@gids);
            my $max;
            # we shall search a range for a free gid
            $gid = $args{min_new_gid} // 0;
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
            [delgroup => {%aargs, name=>$name, gid=>$gid}]]}];
    } elsif ($tx_action eq 'fix_state') {
        $log->infof("Adding Unix group %s ...", $name);
        $pu->group($name, $gid, []);
        if ($Passwd::Unix::Alt::errstr) {
            return [500, "Can't add group $name: $Passwd::Unix::Alt::errstr"];
        } else {
            return [200, "Created"];
            $args{-stash}{result}{gid} = $gid;
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
