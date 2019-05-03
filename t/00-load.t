#!perl -T
use 5.006;
use strict;
use warnings;
use Test::More;

plan tests => 1;

BEGIN {
    use_ok( 'Perl::LanguageServer' ) || print "Bail out!\n";
}

diag( "Testing Perl::LanguageServer $Perl::LanguageServer::VERSION, Perl $], $^X" );
