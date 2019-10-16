package Perl::LanguageServer::DevTool ;

use 5.006;
use strict;
use Moose ;

use File::Basename ;
use Coro ;
use Coro::AIO ;
use Data::Dump qw{dump} ;

no warnings 'uninitialized' ;

# ---------------------------------------------------------------------------

has 'config' =>
    (
    isa => 'HashRef',
    is  => 'ro' 
    ) ; 

# ---------------------------------------------------------------------------

1 ;
