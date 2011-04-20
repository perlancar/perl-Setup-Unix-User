package Setup::UnixUser;
# ABSTRACT: Make sure a Unix user exists

use 5.010;
use strict;
use warnings;
use Log::Any '$log';

require Exporter;
our @ISA       = qw(Exporter);
our @EXPORT_OK = qw(setup_unix_user);

our %SPEC
    summary  => "Make sure a Unix user exists",
    description => <<'_',

On do, will create Unix user if not already exists. Will add/remove user from
groups as specified.

On undo, will delete Unix user previously created (and/or remove/readd groups to
original state).

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
        }],
        new_home_dir => ['str' => {
            summary => 'Set home directory when creating new user',
        }],
        new_shell => ['str' => {
            summary => 'Set shell when creating new user',
        }],
        # XXX new_uid, new_gid?
    },
    features => {undo=>1, dry_run=>1},
};
sub setup_unix_user {
}

1;
