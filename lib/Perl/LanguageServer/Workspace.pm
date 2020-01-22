package Perl::LanguageServer::Workspace ;

use 5.006;
use strict;
use Moose ;

use File::Basename ;
use Coro ;
use Coro::AIO ;
use Data::Dump qw{dump} ;

with 'Perl::LanguageServer::SyntaxChecker' ;
with 'Perl::LanguageServer::Parser' ;

no warnings 'uninitialized' ;

# ---------------------------------------------------------------------------

has 'config' =>
    (
    isa => 'HashRef',
    is  => 'ro' 
    ) ; 

has 'is_shutdown' =>
    (
    isa => 'Bool',
    is  => 'rw',
    default => 0, 
    ) ; 

has 'files' =>
    (
    isa => 'HashRef',
    is  => 'rw',
    default => sub { {} },
    ) ;

has 'folders' =>
    (
    isa => 'HashRef',
    is  => 'rw',
    default => sub { {} },
    ) ;

has 'symbols' =>
    (
    isa => 'HashRef',
    is  => 'rw',
    default => sub { {} },
    ) ;

has 'path_map' =>
    (
    isa => 'Maybe[ArrayRef]',
    is  => 'rw'    
    ) ;

has 'file_filter_regex' =>
    (
    isa => 'Str',
    is  => 'rw',
    default => '(?:\.pm|\.pl)$',
    ) ;

has 'ignore_dir' =>
    (
    isa => 'HashRef',
    is  => 'rw',
    default => sub { { '.git' => 1, '.svn' => 1, '.vscode' => 1 } },
    ) ;

has 'perlcmd' =>
    (
    isa => 'Str',
    is  => 'rw',
    default => $^X,
    ) ;

has 'perlinc' =>
    (
    isa => 'Maybe[ArrayRef]',
    is  => 'rw',
    ) ;


has 'parser_channel' =>
    (
    is => 'rw',
    isa => 'Coro::Channel',
    default => sub { Coro::Channel -> new }    
    ) ;

has 'state_dir' =>
    (
    is => 'rw',
    isa => 'Str',
    lazy_build => 1,
    ) ;

# ---------------------------------------------------------------------------

sub logger
    {
    my $self = shift ;
    
    Perl::LanguageServer::logger (undef, @_) ;    
    }

# ----------------------------------------------------------------------------


sub mkpath
    {
    my ($self, $dir) = @_ ;

    aio_stat ($dir) ;
    if (! -d _)
        {
        $self -> mkpath (dirname($dir)) ; 
        aio_mkdir ($dir, 0755) and die "Cannot make $dir ($!)" ;
        }
    }

# ---------------------------------------------------------------------------

sub _build_state_dir
    {
    my ($self) = @_ ;

    my $root = $self -> config -> {rootUri} || 'file:///tmp' ;
    my $rootpath = substr ($self -> uri_client2server ($root), 7) ;
    $rootpath .= '/.vscode/perl-lang' ;
    print STDERR "state_dir = $rootpath\n" ;
    $self -> mkpath ($rootpath) ;

    return $rootpath ;
    }

# ---------------------------------------------------------------------------


sub shutdown
    {
    my ($self) = @_ ;

    $self -> is_shutdown (1) ;    
    }

# ---------------------------------------------------------------------------

sub uri_server2client
    {
    my ($self, $uri) = @_ ;

    my $map = $self -> path_map ;
    return $uri if (!$map) ;

    #print STDERR ">uri_server2client $uri\n", dump($map), "\n" ;
    foreach my $m (@$map)
        {
        last if ($uri =~ s/$m->[0]/$m->[1]/) ;
        }
    #print STDERR "<uri_server2client $uri\n" ;

    return $uri ;    
    }

# ---------------------------------------------------------------------------

sub uri_client2server
    {
    my ($self, $uri) = @_ ;

    my $map = $self -> path_map ;
    return $uri if (!$map) ;

    #print STDERR ">uri_client2server $uri\n" ;
    foreach my $m (@$map)
        {
        last if ($uri =~ s/$m->[1]/$m->[0]/) ;
        }
    #print STDERR "<uri_client2server $uri\n" ;

    return $uri ;    
    }

# ---------------------------------------------------------------------------

sub file_server2client
    {
    my ($self, $fn) = @_ ;

    my $map = $self -> path_map ;
    return $fn if (!$map) ;

    foreach my $m (@$map)
        {
        #print STDERR "file_server2client $m->[2] -> $m->[3] : $fn\n" ;
        last if ($fn =~ s/$m->[2]/$m->[3]/) ;
        }

    return $fn ;    
    }

# ---------------------------------------------------------------------------

sub file_client2server
    {
    my ($self, $fn) = @_ ;

    my $map = $self -> path_map ;
    return $fn if (!$map) ;

    $fn =~ s/\\/\//g ;

    foreach my $m (@$map)
        {
        #print STDERR "file_client2server $m->[3] -> $m->[2] : $fn\n" ;
        last if ($fn =~ s/$m->[3]/$m->[2]/) ;
        }

    return $fn ;    
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

sub set_workspace_folders
    {
    my ($self, $workspace_folders) = @_ ;
    
    my $folders = $self -> folders ;
    foreach my $ws (@$workspace_folders)
        {
        my $dir = $self -> uri_client2server ($ws -> {uri}) ;
        
        $folders -> {$ws -> {uri}} = substr ($dir, 7) ;    
        }


    }



1 ;

