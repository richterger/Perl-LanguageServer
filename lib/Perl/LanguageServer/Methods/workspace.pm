

package Perl::LanguageServer::Methods::workspace ;

use strict ;
use Moose::Role ;

use Coro ;

use Data::Dump qw{dump} ;

# ---------------------------------------------------------------------------

sub _rpcnot_didChangeConfiguration
    {
    my ($self, $workspace, $req) = @_ ;

    my $log_file   = $req -> params -> {settings}{perl}{logFile} ;
    if ($log_file)
        {
        $Perl::LanguageServer::log_file = $log_file;
        $self -> logger ("log_file = $log_file\n") ;
        }

    $self -> logger ("perl = ", dump ($req -> params -> {settings}{perl}), "\n") ;

    my $log_level   = $req -> params -> {settings}{perl}{logLevel} ;
    if (defined $log_level && length $log_level)
        {
        my $int_log_level = 0+$log_level;
        if ($int_log_level >= 0 && $int_log_level <= 2)
            {
            $Perl::LanguageServer::debug1 = $int_log_level;
            $Perl::LanguageServer::debug2 = $int_log_level > 1?1:0;
            $self -> logger ("log_level = $int_log_level\n") ;
            }
        else
            {
            $self -> logger ("log_level: unexpected value ($log_level)\n") ;
            }
        }

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

    $workspace -> use_taint_for_syntax_check ($req -> params -> {settings}{perl}{useTaintForSyntaxCheck}) ;
    $self -> logger ("use_taint_for_syntax_check = ", dump ( $workspace -> use_taint_for_syntax_check), "\n") ;

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

    if (!exists ($workspace -> config -> {workspaceFolders}) || @{$workspace -> config -> {workspaceFolders} // []} == 0)
        {
        $workspace -> config -> {workspaceFolders} = [{ uri => $workspace -> config -> {rootUri} }] ;
        }

    $workspace -> set_workspace_folders ($workspace -> config -> {workspaceFolders} ) ;

    $workspace -> show_local_vars ($workspace -> config -> {showLocalVars}) ;
    $workspace -> disable_cache   ($workspace -> config -> {disableCache}) ;

    if ($req -> params -> {settings}{perl}{cacheDir})
        {
        $workspace -> state_dir ($req -> params -> {settings}{perl}{cacheDir}) ;
        }
    else
        {
        $workspace -> clear_state_dir
        }

    $workspace -> mkpath ($workspace -> state_dir) ; # force build state dir

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
            next if (!exists $symbol -> {definition}) ;
            $line = $symbol -> {line} ;
            push @vars, { %$symbol, location => { uri => $uri, range => { start => { line => $line, character => 0 }, end => { line => $line, character => 0 }}} } ;
            last if (@vars > 200) ;
            }
        }

    return \@vars ;
    }

# ---------------------------------------------------------------------------

1 ;
