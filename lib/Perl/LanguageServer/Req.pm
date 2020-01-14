package Perl::LanguageServer::Req ;

use strict;
use Moose ;

no warnings 'uninitialized' ;

# ---------------------------------------------------------------------------

has 'id' =>
    (
    isa => 'Maybe[Str]',
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

has 'is_dap' =>
    (
    isa => 'Bool',
    is  => 'rw',
    default => 0, 
    ) ; 

has 'type' =>
    (
    isa => 'Str',
    is  => 'rw',
    ) ; 

# ---------------------------------------------------------------------------

sub cancel_req 
    {
    my ($self) = @_ ;

    $self -> cancel (1) ;

    }


# ---------------------------------------------------------------------------

1 ;

