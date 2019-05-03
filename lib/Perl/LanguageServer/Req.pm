package Perl::LanguageServer::Req ;

use strict;
use Moose ;

no warnings 'uninitialized' ;

# ---------------------------------------------------------------------------

has 'id' =>
    (
    isa => 'Maybe[Int]',
    is  => 'ro' 
    ) ; 

has 'params' =>
    (
    isa => 'HashRef',
    is  => 'ro' 
    ) ; 

has 'cancel' =>
    (
    isa => 'Bool',
    is  => 'rw',
    default => 0, 
    ) ; 

# ---------------------------------------------------------------------------

sub cancel_req 
    {
    my ($self) = @_ ;

    $self -> cancel (1) ;

    }


# ---------------------------------------------------------------------------

1 ;

