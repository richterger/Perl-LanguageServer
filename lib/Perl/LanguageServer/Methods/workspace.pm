

package Perl::LanguageServer::Methods::workspace ;

use strict ;
use Moose::Role ;

use Coro ;

use Data::Dump qw{dump} ;

# ---------------------------------------------------------------------------

sub _rpcnot_didChangeConfiguration
    {
    my ($self, $workspace, $req) = @_ ;

    $self -> logger ("perl = ", dump ($req -> params -> {settings}{perl}), "\n") ;

    my $uri   = $req -> params -> {settings}{perl}{sshWorkspaceRoot} ;
    if ($uri)
        {
        $uri =~ s/\\/\//g ;
        $uri = 'file://' . $uri if ($uri !~ /^file:/) ;
        $workspace -> path_map ([[$uri, $workspace -> config -> {rootUri}]]) ;
        }
    my $map   = $req -> params -> {settings}{perl}{pathMap} ;
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
        $workspace -> path_map ($map) ;
        }

    $self -> logger ("path_map = ", dump ( $workspace -> path_map), "\n") ;    

    my $inc   = $req -> params -> {settings}{perl}{perlInc} ;
    if ($inc)
        {
        $inc = [$inc] if (!ref $inc) ;    
        $workspace -> perlinc ($inc) ;    
        }

    $self -> logger ("perlinc = ", dump ( $workspace -> perlinc), "\n") ;    

    my $filter   = $req -> params -> {settings}{perl}{fileFilter} ;
    if ($filter)
        {
        $filter = [$filter] if (!ref $filter) ;    
        $workspace -> file_filter_regex ('(?:' . join ('|', map { quotemeta($_) } @$filter ) . ')$') ;    
        }

    $self -> logger ("file_filter_regex = ", dump ( $workspace -> file_filter_regex), "\n") ;    

    my $dirs   = $req -> params -> {settings}{perl}{ignoreDirs} ;
    if ($dirs)
        {
        $dirs = [$dirs] if (!ref $dirs) ;    
        $workspace -> ignore_dir ({ map { ( $_ => 1 ) } @$dirs }) ;    
        }

    $self -> logger ("ignore_dir = ", dump ( $workspace -> ignore_dir), "\n") ;    

    if (!exists ($workspace -> config -> {workspaceFolders}) || @{$workspace -> config -> {workspaceFolders}} == 0)
        {
        $workspace -> config -> {workspaceFolders} = [{ uri => $workspace -> config -> {rootUri} }] ;
        }

    $workspace -> set_workspace_folders ($workspace -> config -> {workspaceFolders} ) ;

    $workspace -> show_local_vars ($workspace -> config -> {showLocalVars}) ;
    $workspace -> disable_cache   ($workspace -> config -> {disableCache}) ;

    async
        {
        $workspace -> background_parser ($self) ;
        } ;

    async
        {
        $workspace -> background_checker ($self) ;
        } ;


    return ;
    }

# ---------------------------------------------------------------------------


sub _rpcnot_didChangeWorkspaceFolders
    {
    my ($self, $workspace, $req) = @_ ;

    my $added = $req -> params -> {event}{added} ;
    if ($added)
        {
        $workspace -> set_workspace_folders ($added) ;
        }
        
    my $removed = $req -> params -> {event}{removed} ;
    if ($removed)
        {
        foreach my $folder (@$removed)
            {
            my $uri = $folder -> {uri} ;
            #TODO    
            }    
        }

    async
        {
        $workspace -> background_parser ($self) ;
        } ;

    }

# ---------------------------------------------------------------------------

sub _rpcreq_symbol
    {
    my ($self, $workspace, $req) = @_ ;

    my $query = $req -> params -> {query} || '.' ;
    my $symbols = $workspace -> symbols ;
    #$self -> logger ("symbols = ", dump ($symbols), "\n") ;
    my $line ;
    my @vars ;

    foreach my $uri (keys %$symbols)
        {
        foreach my $symbol (@{$symbols->{$uri}})
            {
            next if ($symbol -> {name} !~ /$query/) ;
            next if (!exists $symbol -> {defintion}) ;
            $line = $symbol -> {line} ;
            push @vars, { %$symbol, location => { uri => $uri, range => { start => { line => $line, character => 0 }, end => { line => $line, character => 0 }}} } ;
            last if (@vars > 200) ;
            }
        }

    return \@vars ;
    }

# ---------------------------------------------------------------------------

1 ;
