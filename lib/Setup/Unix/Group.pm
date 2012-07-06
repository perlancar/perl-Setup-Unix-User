package Setup::Unix::Group;

use 5.010;
use strict;
use warnings;
use Log::Any '$log';

require Exporter;
our @ISA       = qw(Exporter);
our @EXPORT_OK = qw(setup_unix_group);

use Passwd::Unix::Alt;
use Perinci::Sub::Gen::Undoable 0.13 qw(gen_undoable_func);

# VERSION

sub _create_pu_object {
    my $args = shift;

    my $passwd_path  = $args->{_passwd_path}  // "/etc/passwd";
    my $group_path   = $args->{_group_path}   // "/etc/group";
    my $shadow_path  = $args->{_shadow_path}  // "/etc/shadow";
    my $gshadow_path = $args->{_gshadow_path} // "/etc/gshadow";
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

sub _check_or_fix {
    my ($which, $args, $step, $undo, $r, $rmeta) = @_;
    my $name = $args->{name};

    my $pu = _create_pu_object($args);
    my $gid;

    my @g = $pu->group($name);
    if ($Passwd::Unix::Alt::errstr &&
            $Passwd::Unix::Alt::errstr !~ /unknown group/i) {
        return [500, "Can't check group entry: $Passwd::Unix::Alt::errstr"];
    }

    if ($step->[0] eq 'create') {

        $gid = $step->[1];
        if ($g[0]) {
            if (!defined($gid)) {
                return [304, "Group already exists"];
            } elsif ($gid ne $g[0]) {
                return [412, "Group already exists but with different GID ".
                            "$g[0] (we need to create GID $g[0])"];
            }
        } else {
            my $found = defined($gid);
            if (!$found) {
                $log->trace("finding an unused GID ...");
                my @gids = map {($pu->group($_))[0]} $pu->groups;
                #$log->tracef("gids = %s", \@gids);
                my $max;
                # we shall search a range for a free gid
                $gid = $args->{min_new_gid} // 1;
                $max = $args->{max_new_gid} // 65535;
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
            return [412, "Can't find unused GID"] unless $found;

            if ($which eq 'check') {
                return [200, "OK", ["delete", $gid]]; # undo step
            } else {
                $pu->group($name, $gid, []);
                if ($Passwd::Unix::Alt::errstr) {
                    return [500, "Can't add group entry: ".
                                "$Passwd::Unix::Alt::errstr"];
                }
                $r->{gid} = $gid;
                return [200, "Created"];
            }
        }

    } elsif ($step->[0] eq 'delete') {

        return [304, "Group doesn't exist"] unless $g[0];

        if ($which eq 'check') {
            return [200, "OK", ['create', $g[0]]]; # undo step
        } else {
            $pu->del_group($name);
            if ($Passwd::Unix::Alt::errstr) {
                return [500, "Can't delete group: $Passwd::Unix::Alt::errstr"];
            }
            $r->{gid} = $gid;
            return [200, "Deleted"];
        }

    }
}

my $res = gen_undoable_func(
    name => 'setup_unix_group',
    summary => "Setup Unix group (existence)",
    description => <<'_',

On do, will create Unix group if not already exists. The created GID will be
returned in the result.

On undo, will delete Unix group previously created.

On redo, will recreate the Unix group with the same GID.

_
    args => {
        name => {
            schema  => 'str*',
            summary => 'Group name',
        },
        min_new_gid => {
            schema  => ['int' => {default => 0}],
            summary => 'When creating new group, specify minimum GID',
        },
        max_new_gid => {
            schema  => ['int' => {default => 65534}],
            summary => 'When creating new group, specify maximum GID',
        },
    },

    check_args => sub {
        my $args = shift;
        $args->{name} or return [400, "Please specify name"];
        $args->{name} =~ /^[A-Za-z0-9_-]+$/
            or return [400, "Invalid group name syntax"];
        [200, "OK"];
    },

    build_steps => sub {
        my $args = shift;
        my $name = $args->{name};

        my $pu = _create_pu_object($args);
        my @steps;

        my @g = $pu->group($name);
        return [500, "Can't get Unix group: $Passwd::Unix::Alt::errstr"]
            if $Passwd::Unix::Alt::errstr &&
                $Passwd::Unix::Alt::errstr !~ /unknown group/i;
        if (!$g[0]) {
            $log->info("nok: unix group $name doesn't exist");
            push @steps, ["create"];
        }

        [200, "OK", \@steps];
    },

    steps => {
        create => {
            summary => 'Create group',
            description => <<'_',

Pass GID argument if you want to create group with specific ID. Otherwise, the
first available ID will be used.

_
            check_or_fix => \&_check_or_fix,
        },
        delete => {
            summary => 'Delete group',
            check_or_fix => \&_check_or_fix,
        },
    },
);

die "Can't generate function: $res->[0] - $res->[1]" unless $res->[0] == 200;

1;
# ABSTRACT: Setup Unix group (existence)

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

This module is part of the L<Setup> modules family.

This module uses L<Log::Any> logging framework.

This module has L<Rinci> metadata.


=head1 FAQ

=head2 How to create group with a specific GID?

Set C<min_new_gid> and C<max_new_gid> to your desired value. Note that the
function will report failure if when wanting to create a group, the desired GID
is already taken. But the function will not report failure if the group already
exists, even with a different GID.


=head1 SEE ALSO

L<Setup::Unix::User>

L<Setup>

=cut
