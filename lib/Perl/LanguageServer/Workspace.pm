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

has 'use_taint_for_syntax_check' =>
    (
    isa => 'Maybe[Bool]',
    is  => 'rw'
    ) ;

has 'show_local_vars' =>
    (
    isa => 'Maybe[Bool]',
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
    clearer => 'clear_state_dir',
    ) ;

has 'disable_cache' =>
    (
    isa => 'Maybe[Bool]',
    is  => 'rw',
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
    $rootpath =~ s#^/(\w)%3A/#$1:/# ;
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
    my ($self, $fn, $map) = @_ ;

    $map ||= $self -> path_map ;
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
    my ($self, $fn, $map) = @_ ;

    $map ||= $self -> path_map ;
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

sub set_workspace_folders
    {
    my ($self, $workspace_folders) = @_ ;

    my $folders = $self -> folders ;
    foreach my $ws (@$workspace_folders)
        {
        my $diruri = $self -> uri_client2server ($ws -> {uri}) ;

        my $dir = substr ($diruri, 7) ;
        $dir =~ s#^/(\w)%3A/#$1:/# ;
        $folders -> {$ws -> {uri}} = $dir ;
        }
    }

# ---------------------------------------------------------------------------

sub add_diagnostic_messages
    {
    my ($self, $server, $uri, $source, $messages, $version) = @_ ;

    my $files = $self -> files ;
    $files -> {$uri}{messages}{$source} = $messages ;
    $files -> {$uri}{messages_version}  = $version if (defined ($version));

    # make sure all old messages associated with this uri are cleaned up
    my %diags = ( map { $_ => [] } @{$files -> {$uri}{diags} } ) ;
    foreach my $src (keys %{$files -> {$uri}{messages}})
        {
        my $msgs = $files -> {$uri}{messages}{$src} ;
        if ($msgs && @$msgs)
            {
            my $line ;
            my $lineno = 0 ;
            my $filename ;
            my $lastline = 1 ;
            my $msg ;
            my $severity ;
            foreach $line (@$msgs)
                {
                ($filename, $lineno, $severity, $msg) = @$line ;
                if ($lineno)
                    {
                    if ($msg)
                        {
                        my $diag =
                            {
                            #   range: Range;
                            #	severity?: DiagnosticSeverity;
                            #	code?: number | string;
                            #   codeDescription?: CodeDescription;
                            #   source?: string;
                            #   message: string;
                            #   tags?: DiagnosticTag[];
                            #   relatedInformation?: DiagnosticRelatedInformation[];
                            #   data?: unknown;

                            # DiagnosticSeverity
                            # const Error: 1 = 1;
                            # const Warning: 2 = 2;
                            # const Information: 3 = 3;
                            # const Hint: 4 = 4;

                            # DiagnosticTag
                            #  * Clients are allowed to render diagnostics with this tag faded out
                            #  * instead of having an error squiggle.
                            # export const Unnecessary: 1 = 1;
                            #  * Clients are allowed to rendered diagnostics with this tag strike through.
                            # export const Deprecated: 2 = 2;

                            # DiagnosticRelatedInformation
                            #  * Represents a related message and source code location for a diagnostic.
                            #  * This should be used to point to code locations that cause or are related to
                            #  * a diagnostics, e.g when duplicating a symbol in a scope.
                            #
                            # 	 * The location of this related diagnostic information.
                            # 	location: Location;
                            # 	 * The message of this related diagnostic information.
                            # 	message: string;

                            range => { start => { line => $lineno-1, character => 0 }, end => { line => $lineno+0, character => 0 }},
                            ($severity?(severity => $severity + 0):()),
                            message => $msg,
                            source  => $src,
                            } ;
                        $diags{$filename} ||= [] ;
                        push @{$diags{$filename}}, $diag ;
                        }
                    $lastline = $lineno ;
                    $lineno = 0 ;
                    $msg    = '' ;
                    }
                }
            }
        }
    $files -> {$uri}{diags} = [keys %diags] ;

    foreach my $filename (keys %diags)
        {
        my $fnuri = !$filename || $filename eq '-'?$uri:$self -> uri_server2client ('file://' . $filename) ;
        my $result =
            {
            method => 'textDocument/publishDiagnostics',
            params =>
                {
                uri => $fnuri,
                diagnostics => $diags{$filename},
                },
            } ;

        $server -> send_notification ($result) ;
        }
    }

# ---------------------------------------------------------------------------


1 ;

