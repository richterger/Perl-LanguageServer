#!perl
use 5.006;
use strict;
use warnings;
use Test::More;

plan tests => 1;

use FindBin '$Bin';
use lib "$FindBin::Bin/../lib";

use Perl::LanguageServer::Parser;

my $source = <<'SOURCE';
package My::Package;
use strict;

our $VAR1 = 1;
my $VAR2 = 2;

sub new {};

1;
SOURCE

my $expected = [
    {
        'line' => 0,
        'name' => 'My::Package',
        'definition' => 1,
        'kind' => 2
    },
    {
        'line' => 1,
        'kind' => 2,
        'name' => 'strict',
        'containerName' => ''
    },
    {
        'line' => 3,
        'kind' => 13,
        'name' => '$VAR1',
        'definition' => 'our',
        'containerName' => 'My::Package'
    },
    {
        'containerName' => undef,
        'localvar' => 'my',
        'line' => 4,
        'name' => '$VAR2',
        'definition' => 'my',
        'kind' => 13
    },
    {
        'containerName' => 'My::Package',
        'range' => {
            'start' => {
                'character' => 0,
                'line' => 6
            },
            'end' => {
                'character' => 9999,
                'line' => 6
            }
        },
        'children' => [],
        'line' => 6,
        'name' => 'new',
        'definition' => 'sub',
        'kind' => 12
    }
];

my $server = bless({}, 'MyDummyServer');
{
    no strict 'refs';
    *{'MyDummyServer::logger'} = sub {};
}

my $uri = undef;
my ($vars, $tokens) = Perl::LanguageServer::Parser->parse_perl_source($uri, $source, $server);

is_deeply($vars, $expected, 'Structure');
