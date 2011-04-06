package Spanel::Setup::Common::UnixUser;

use 5.010;
use strict;
use warnings;
use Log::Any '$log';

require Exporter;
our @ISA       = qw(Exporter);
our @EXPORT_OK = qw(create_user);

sub create_user {
    my %args  = @_;
    my $dry   = $args{-dry_run};
    my $undo  = $args{-undo};
    my $state = $args{-state};

    my $user    = $args{symlink};
    my $target  = $args{target};

    my ($ok, $nok_msg, $bail);
    my $is_symlink = (-l $symlink); # lstat
    my $exists     = (-e _);        # now we can use -e
    my $curtarget  = $is_symlink ? readlink($symlink) : "";
    if ($undo) {
        my $ud = get_unsetup_data($subname);
        $ok = !$ud->{created} || !$exists || !$is_symlink ||
            $curtarget ne $ud->{target};
        $nok_msg = "Symlink $symlink exists and was created by us" if !$ok;
    } else {
        if (!$exists) {
            $ok = 0;
            $nok_msg = "Symlink $symlink doesn't exist";
        } elsif (!$is_symlink) {
            $ok = 0;
            $nok_msg = "$symlink is not a symlink";
            $bail++; # bail out, we won't fix this, dangerous
        } elsif ($curtarget ne $target) {
            $ok = 0;
            $nok_msg = "$symlink points to $curtarget instead of $target";
        } else {
            $ok = 1;
        }
    }

    return [304, "OK"] if $ok;
    return [412, $nok_msg] if $dry_run || $bail;

    use autodie;
    if ($unsetup) {
        $log->trace("rm $symlink");
        unlink $symlink;
        delete_unsetup_data($subname);
    } else {
        $log->tracef("symlink %s -> %s", $symlink, $target);
        symlink $target, $symlink;
         set_unsetup_data($subname, {created=>1, target=>$target});
    }
    [200, "Fixed"];
}

1;
