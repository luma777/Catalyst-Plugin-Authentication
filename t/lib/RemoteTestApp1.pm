package RemoteTestApp1;
use strict;
use warnings;
use Catalyst qw/
   Authentication
/;

use base qw/Catalyst/;
__PACKAGE__->engine_class('RemoteTestEngine');
__PACKAGE__->config(
    'Plugin::Authentication' => {
        default_realm => 'remote',
        realms => {
            remote => {
                credential => {
                    class => 'Remote',
                    allow_regexp => '^(bob|john|CN=.*)$',
                    deny_regexp=> 'denied',
                    cutname_regexp=> 'CN=(.*)/OU=Test',
                },
                store => {
                    class => 'Null',
                },
            },
        },
    },
);

__PACKAGE__->setup;

1;

