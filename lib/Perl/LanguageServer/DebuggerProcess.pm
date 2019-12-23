package Perl::LanguageServer::DebuggerProcess ;

use 5.006;
use strict;
use Moose ;

use File::Basename ;
use Coro ;
use Coro::AIO ;
use Data::Dump qw{dump} ;

with 'Perl::LanguageServer::IO' ;

no warnings 'uninitialized' ;

our $session_cnt = 1 ;

# ---------------------------------------------------------------------------

has 'program' =>
    (
    isa => 'Str',
    is  => 'ro' 
    ) ; 

has 'args' =>
    (
    isa => 'ArrayRef',
    is  => 'ro',
    default => sub { [] },
    ) ; 

has 'env' =>
    (
    isa => 'ArrayRef',
    is  => 'ro',
    default => sub { [] },
    ) ; 

has 'cwd' =>
    (
    isa => 'Maybe[Str]',
    is  => 'ro',
    ) ; 

has 'stop_on_entry' =>
    (
    isa => 'Bool',
    is  => 'ro' 
    ) ; 

has 'session_id' =>
    (
    isa => 'Str',
    is  => 'ro' 
    ) ; 

has 'type' =>
    (
    isa => 'Str',
    is  => 'ro' 
    ) ; 

has 'debug_adapter' =>
    (
    isa => 'Perl::LanguageServer',
    is  => 'rw',
    weak_ref => 1, 
    ) ; 

has 'pid' =>
    (
    isa => 'Int',
    is  => 'rw' 
    ) ; 


# ---------------------------------------------------------------------------

sub BUILDARGS
    {
    my ($class, $args) = @_ ;

    $args -> {stop_on_entry} = delete $args -> {stopOnEntry}?1:0 ;
    $args -> {session_id}    = delete $args -> {__sessionId} || $session_cnt ;
    $session_cnt++ ;

    return $args ;
    }

# ---------------------------------------------------------------------------

sub logger
    {
    my $self = shift ;

    $self -> debug_adapter -> logger (@_) ;
    }

# ---------------------------------------------------------------------------

sub send_event
    {
    my ($self, $event, $body) = @_ ;

    $self -> debug_adapter -> send_event ($event, $body) ;
    }

# ---------------------------------------------------------------------------

sub lauch
    {
    my ($self, $workspace, $cmd) = @_ ;

    my $fn = $workspace -> file_client2server ($self -> program) ;
    my $pid ;
    {
    local %ENV ;
    foreach (@{$self -> env})
        {
        $ENV{$_} = $self -> env -> {$_} ;    
        }
    
    $ENV{PLSDI_REMOTE} = '127.0.0.1:' . $self -> debug_adapter -> listen_port ;
    $ENV{PERL5DB}      = 'BEGIN { require Perl::LanguageServer::DebuggerInterface }' ;
    $ENV{PLSDI_SESSION}= $self -> session_id ;
    $pid = $self -> run_async ([$cmd, '-d', $fn, @{$self -> args}]) ;
    }

    $self -> pid ($pid) ;
    $self -> send_event ('process', 
                        { 
                        name            => $self -> program, 
                        systemProcessId => $pid, 
                        isLocalProcess  => JSON::true(),
                        startMethod     => 'launch',
                        }) ;

    return ;
    }

# ---------------------------------------------------------------------------

sub signal
    {
    my ($self, $signal) = @_ ;

    return if (!$self -> pid) ;

    kill $signal, $self -> pid ;
    }

# ---------------------------------------------------------------------------

sub on_stdout
    {
    my ($self, $data) = @_ ;

    foreach my $line (split /\r?\n/, $data)
        {
        $self -> send_event ('output', { category => 'stdout', output => $line . "\r\n" }) ;
        }
    }

# ---------------------------------------------------------------------------

sub on_stderr
    {
    my ($self, $data) = @_ ;

    foreach my $line (split /\r?\n/, $data)
        {
        $self -> send_event ('output', { category => 'stderr', output => $line . "\r\n" }) ;
        }
    }

# ---------------------------------------------------------------------------

sub on_exit
    {
    my ($self, $data) = @_ ;

    $self -> send_event ('terminated') ;
    $self -> send_event ('exited', { exitCode => ($data>>8)&0xff }) ;
    }

# ---------------------------------------------------------------------------

1 ;

