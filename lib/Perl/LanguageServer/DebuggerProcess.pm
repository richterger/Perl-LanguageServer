package Perl::LanguageServer::DebuggerProcess ;

use 5.006;
use strict;
use Moose ;

use Encode::Locale;
use Encode;
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
    isa => 'ArrayRef | Str',
    is  => 'ro',
    default => sub { [] },
    ) ;

has 'env' =>
    (
    isa => 'HashRef',
    is  => 'ro',
    default => sub { {} },
    ) ;

has 'cwd' =>
    (
    isa => 'Maybe[Str]',
    is  => 'ro',
    ) ;

has 'sudo_user' =>
    (
    isa => 'Maybe[Str]',
    is  => 'ro',
    ) ; 

has 'use_taint_for_debug' =>
    (
    isa => 'Bool',
    is  => 'rw'
    ) ;

has 'path_map' =>
    (
    isa => 'Maybe[ArrayRef]',
    is  => 'rw'
    ) ;

has 'stop_on_entry' =>
    (
    isa => 'Bool',
    is  => 'ro'
    ) ;

has 'reload_modules' =>
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

    $args -> {env} = { @{$args -> {env}} } if (exists $args -> {env} && ref ($args -> {env}) eq 'ARRAY') ;
    $args -> {reload_modules} = delete $args -> {reloadModules}?1:0 ;
    $args -> {stop_on_entry} = delete $args -> {stopOnEntry}?1:0 ;
    $args -> {session_id}    = delete $args -> {__sessionId} || $session_cnt ;
    $args -> {sudo_user}    = delete $args -> {sudoUser} ;
    $args -> {use_taint_for_debug} = delete $args -> {useTaintForDebug} ;
    my $map   = delete $args -> {pathMap} ;
    if ($map)
        {
        my $fn ;
        foreach (@$map)
            {
            $fn = $_ -> [0] ;
            $fn =~ s/^file:// ;
            $fn =~ s/^\/\/\//\// ;
            $_ -> [2] ||= $fn ;
            $fn = $_ -> [1] ;
            $fn =~ s/^file:// ;
            $fn =~ s/^\/\/\//\// ;
            $_ -> [3] ||= $fn ;
            }
        $args -> {path_map} = $map ;
        }

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

sub file_server2client
    {
    my ($self, $workspace, $fn) = @_ ;

    return $workspace -> file_server2client ($fn, $self -> path_map) ;
    }

# ---------------------------------------------------------------------------

sub file_client2server
    {
    my ($self, $workspace, $fn) = @_ ;

    return $workspace -> file_client2server ($fn, $self -> path_map) ;
    }

# ---------------------------------------------------------------------------

sub add_path_mapping
    {
    my ($self, $fn_server, $fn_client) = @_ ;
    my $map = $self -> path_map ;
    $map = $self -> path_map ([]) if (!$map) ;


    foreach my $m (@$map)
        {
        #print STDERR "add file_server2client $m->[2] -> $m->[3]\n" ;
        return if ($fn_server eq $m->[2]) ;
        }

    unshift @$map, ['file://' . $fn_server, 'file://' . $fn_client, $fn_server, $fn_client] ;
    return  ;
    }

# ---------------------------------------------------------------------------

sub send_event
    {
    my ($self, $event, $body) = @_ ;

    $self -> debug_adapter -> send_event ($event, $body) ;
    }

# ---------------------------------------------------------------------------

sub launch
    {
    my ($self, $workspace, $cmd) = @_ ;

    my $fn = $self -> file_client2server ($workspace, $self -> program) ;
    my $pid ;
    {
    local %ENV = %ENV ;
    my @sudoargs ;
    if ($self->sudo_user)
        {
        push @sudoargs, "sudo", "-u", $self->sudo_user ;
        }
    foreach (keys %{$self -> env})
        {
        $ENV{$_} = $self -> env -> {$_} ;
        push @sudoargs, "$_=" . $self -> env -> {$_} if $self->sudo_user;
        }

    my $cwd ;
    if ($self -> cwd)
        {
        my $dir = $self -> cwd ;
        $dir =~ s/'//g ;
        $cwd = " chdir '$dir'; " ;
        }

    my $inc = $workspace -> perlinc ;
    my @inc ;
    @inc = map { ('-I', $_)} @$inc if ($inc) ;

    $ENV{PLSDI_REMOTE} = '127.0.0.1:' . $self -> debug_adapter -> listen_port ;
    $ENV{PLSDI_OPTIONS} = $self -> reload_modules?'reload_modules':'' ;
    $ENV{PERL5DB}      = 'BEGIN { $| = 1 ; ' . $cwd . 'require Perl::LanguageServer::DebuggerInterface; DB::DB(); }' ;
    $ENV{PLSDI_SESSION}= $self -> session_id ;
    if ($self->sudo_user)
        {
        push @sudoargs, "PLSDI_REMOTE=$ENV{PLSDI_REMOTE}" ;
        push @sudoargs, "PLSDI_OPTIONS=$ENV{PLSDI_OPTIONS}" ;
        push @sudoargs, "PERL5DB=$ENV{PERL5DB}" ;
        push @sudoargs, "PLSDI_SESSION=$ENV{PLSDI_SESSION}" ;
        }
    if ($self->use_taint_for_debug)
        {
        push @inc, "-T" ;
        }

    if (ref $self -> args)       # ref is array
        {
        $pid = $self -> run_async ([@sudoargs, $cmd, @inc, '-d', $fn, @{$self -> args}]) ;
        } 
    else                      # no ref is string
        {
        $pid = $self -> run_async (join (' ', @sudoargs, $cmd, @inc, '-d', $fn, $self -> args)) ;
        }
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

    $self -> logger ("Send signal $signal to debuggee\n") ;

    kill $signal, $self -> pid ;
    }

# ---------------------------------------------------------------------------

sub on_stdout
    {
    my ($self, $data) = @_ ;

    foreach my $line (split /\r?\n/, $data)
        {
        $line = decode(locale => $line);
        $self -> send_event ('output', { category => 'stdout', output => $line . "\r\n" }) ;
        }
    }

# ---------------------------------------------------------------------------

sub on_stderr
    {
    my ($self, $data) = @_ ;

    foreach my $line (split /\r?\n/, $data)
        {
        $line = decode(locale => $line);
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

