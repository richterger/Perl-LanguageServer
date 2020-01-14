package Perl::LanguageServer::Methods::textDocument ;

use Moose::Role ;

use Coro ;
use Coro::AIO ;



# ---------------------------------------------------------------------------

sub get_symbol_from_doc
    {
    my ($self, $workspace, $uri, $pos) = @_ ;

    my $files = $workspace -> files ;
    my $text = $files -> {$uri}{text} ;
    my $line = $pos -> {line} ;
    my $char = $pos -> {character} ;

    $text =~ /(?:.*?\n){$line}(.*?)\n/ ;
    my $data = $1 ;
    print STDERR "line $line: <$data>\n" ;

    while ($data =~ /([a-zA-Z0-9_\$\%\@]+)/g)
        {
        my $pos = pos ($data) ;
        my $len = length ($1) ;
        $self -> logger ("word: <$1> pos: $pos len: $len\n") if ($Perl::LanguageServer::debug2) ;
        if ($char <= $pos && $char >= $pos - $len)
            {
            $self -> logger ("ok\n") if ($Perl::LanguageServer::debug2) ;
            return $1 ;
            }
        }

    return ;
    }

# ---------------------------------------------------------------------------

sub _rpcnot_didOpen
    {
    my ($self, $workspace, $req) = @_ ;

    my $files = $workspace -> files ;
    my $uri   = $req -> params -> {textDocument}{uri} ;
    my $text  = $req -> params -> {textDocument}{text} ;
    $files -> {$uri}{text} = $text ;
    delete $files -> {$uri}{vars} ;

    $workspace -> check_perl_syntax ($workspace, $uri, $text) ;

    return ;
    }

# ---------------------------------------------------------------------------

sub _rpcnot_didChange
    {
    my ($self, $workspace, $req) = @_ ;

    my $files = $workspace -> files ;
    my $uri   = $req -> params -> {textDocument}{uri} ;
    my $text  = $req -> params -> {contentChanges}[0]{text} ;

    $files -> {$uri}{text} = $text ;
    delete $files -> {$uri}{vars} ;

    $workspace -> check_perl_syntax ($workspace, $uri, $text) ;

    return ;
    }

# ---------------------------------------------------------------------------

sub _rpcnot_didClose
    {
    my ($self, $workspace, $req) = @_ ;

    my $files = $workspace -> files ;
    my $uri   = $req -> params -> {textDocument}{uri} ;
    delete $files -> {$uri}{text} ;
    delete $files -> {$uri}{vars} ;

    return ;
    }

# ---------------------------------------------------------------------------

sub _rpcnot_didSave
    {
    my ($self, $workspace, $req) = @_ ;

    my $uri   = $req -> params -> {textDocument}{uri} ;
    $workspace -> parser_channel -> put (['save', $uri]) ;
    }

# ---------------------------------------------------------------------------

sub _rpcreq_documentSymbol
    {
    my ($self, $workspace, $req) = @_ ;

    my $files = $workspace -> files ;
    my $uri   = $req -> params -> {textDocument}{uri} ;
    my $text  = $files -> {$uri}{text} ;
    return [] if (!$text) ;

    my $vars  = $files -> {$uri}{vars} ;

    if (!$vars)
        {
        $vars = $workspace -> parse_perl_source ($uri, $text) ;
        $files -> {$uri}{vars} = $vars ;
        }
    my @vars ;
    foreach my $v (@$vars)
        {
        push @vars, $v if (exists $v -> {defintion}) ;    
        }    
    return \@vars ;
    }

# ---------------------------------------------------------------------------

sub _get_symbols
    {
    my ($self, $workspace, $req, $def_only) = @_ ;

    my $pos = $req -> params -> {position} ;
    my $uri = $req -> params -> {textDocument}{uri} ;

    my $name = $self -> get_symbol_from_doc ($workspace, $uri, $pos) ;

    my $symbols = $workspace -> symbols ;
    #print STDERR "symbols = ", dump ($symbols), "\n" ;
    my $line ;
    my @vars ;

    if ($name)
        {
        foreach my $uri (keys %$symbols)
            {
            foreach my $symbol (@{$symbols->{$uri}})
                {
                next if ($symbol -> {name} ne $name) ;
                next if ($def_only && !exists $symbol -> {defintion}) ;
                $line = $symbol -> {line} ;
                push @vars, { uri => $uri, range => { start => { line => $line, character => 0 }, end => { line => $line, character => 0 }}} ;
                last if (@vars > 200) ;
                }
            }
        }

    return \@vars ;
    }
# ---------------------------------------------------------------------------

sub _rpcreq_definition
    {
    my ($self, $workspace, $req) = @_ ;

    return $self -> _get_symbols ($workspace, $req, 1) ;
    }

# ---------------------------------------------------------------------------

sub _rpcreq_references
    {
    my ($self, $workspace, $req) = @_ ;

    return $self -> _get_symbols ($workspace, $req, 0) ;
    }

# ---------------------------------------------------------------------------

1 ;
