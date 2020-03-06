package Perl::LanguageServer::Methods::textDocument ;

use Moose::Role ;

use Coro ;
use Coro::AIO ;
use Data::Dump qw{pp} ;

no warnings 'uninitialized' ;


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
    my $datapos = $-[1] ;
    $self -> logger ("line $line: <$data>\n") if ($Perl::LanguageServer::debug2) ;

    while ($data =~ /([a-zA-Z0-9_\$\%\@]+)/g)
        {
        my $pos = pos ($data) ;
        my $len = length ($1) ;
        $self -> logger ("word: <$1> pos: $pos len: $len\n") if ($Perl::LanguageServer::debug2) ;
        if ($char <= $pos && $char >= $pos - $len)
            {
            $self -> logger ("ok\n") if ($Perl::LanguageServer::debug2) ;
            return wantarray?($1, $datapos + $-[1]):$1 ;
            }
        }

    return ;
    }

# ---------------------------------------------------------------------------

sub get_symbol_before_left_parenthesis
    {
    my ($self, $workspace, $uri, $pos) = @_ ;

    my $files = $workspace -> files ;
    my $text = $files -> {$uri}{text} ;
    my $line = $pos -> {line} ;
    my $char = $pos -> {character} - 1 ;
    my $cnt  = 1 ; 
    my $i ;
    my $endpos ;
    my @symbol ;
    my $symbolpos ;

    while ($line > 0)
        {
        $text =~ /(?:.*?\n){$line}(.*?)(?:\n|$)/ ;
        my $data = $1 ;
        $endpos //= $-[1] + $char ;
        my $datapos = $-[1] ;
        $self -> logger ("line $line: <$data>\n") if ($Perl::LanguageServer::debug2) ;
        $char = length ($data) - 1 if (!defined ($char)) ;
        for ($i = $char; $i >= 0; $i--)
            {
            my $c = substr ($data, $i, 1) ;
            if ($cnt == 0)
                {
                if ($c =~ /\w/)
                    {
                    push @symbol, $c ;
                    $symbolpos = $datapos + $i ;
                    next ;
                    }
                elsif (@symbol)
                    {
                    last ;
                    }
                elsif ($c eq ';')
                    {
                    return ;
                    }
                @symbol = () ;
                }
            if ($c eq '(')
                {
                $cnt--
                }
            elsif ($c eq ')')
                {
                $cnt++
                }
            elsif ($c eq ';')
                {
                return ;
                }
            }
        last if (@symbol) ;
        $line-- ;
        $char = undef ;
        }    

    my $method ;
    for ($i = $symbolpos - 1 ; $i > 0; $i--)
        {
        my $c = substr ($text, $i, 1) ;
        if ($c eq '>' && substr ($text, $i - 1, 1) eq '-')
            {
            $method = 1 ;
            last ;
            }
        last if ($c !~ /\s/) ;
        }


    my $symbol = join ('', reverse @symbol) ;
    return ($symbol, substr ($text, $symbolpos, $endpos - $symbolpos + 1), $symbolpos, $endpos, $method) ;
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

sub _filter_children
    {
    my ($self, $children, $show_local_vars) = @_ ;

    my @vars ;
    foreach my $v (@$children)
        {
        if (exists $v -> {defintion} && (!exists $v -> {localvar} || $show_local_vars))
            {
            if (exists $v -> {children})
                {
                push @vars, { %$v, children => $self -> _filter_children ($v -> {children})} ;    
                }
            else
                {
                push @vars, $v  ;
                }
            }
        }    
    return \@vars ;
    }

# ---------------------------------------------------------------------------

sub _rpcreq_documentSymbol
    {
    my ($self, $workspace, $req) = @_ ;

    my $files = $workspace -> files ;
    my $uri   = $req -> params -> {textDocument}{uri} ;
    my $text  = $files -> {$uri}{text} ;
    return [] if (!$text) ;

    my $show_local_vars = $workspace -> show_local_vars ;
    my $vars  = $files -> {$uri}{vars} ;

    if (!$vars)
        {
        $vars = $workspace -> parse_perl_source ($uri, $text) ;
        $files -> {$uri}{vars} = $vars ;
        }
    my @vars ;
    foreach my $v (@$vars)
        {
        if (exists $v -> {defintion} && (!exists $v -> {localvar} || $show_local_vars))
            {
            if (exists $v -> {children})
                {
                push @vars, { %$v, children => $self -> _filter_children ($v -> {children})} ;    
                }
            else
                {
                push @vars, $v  ;
                }
            }
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

sub _rpcreq_signatureHelp
    {
    my ($self, $workspace, $req) = @_ ;

    my $pos = $req -> params -> {position} ;
    my $uri = $req -> params -> {textDocument}{uri} ;
    $self -> logger (pp($req -> params)) ;

    my ($name, $expr, $symbolpos, $endpos, $method) = $self -> get_symbol_before_left_parenthesis ($workspace, $uri, $pos) ;

    return { signatures => [] } if (!$name) ;

    my $argnum = 0 ;
    while ($expr =~ /,/g)
        {
        $argnum++ ;
        }
    $argnum += ($method?1:0) ;

    my $symbols = $workspace -> symbols ;
    my $line ;
    my @vars ;

    foreach my $uri (keys %$symbols)
        {
        foreach my $symbol (@{$symbols->{$uri}})
            {
            next if ($symbol -> {name} ne $name) ;
            next if (!exists $symbol -> {defintion}) ;
            next if (!exists $symbol -> {signature}) ;

            push @vars, $symbol -> {signature} ;
            last if (@vars > 200) ;
            }
        }
 
    $self -> logger (pp(\@vars))  if ($Perl::LanguageServer::debug2) ;

    my $signum = 0 ;
    my $context = $req -> params -> {context} ;
    if ($context)
        {
        $signum = $context -> {activeSignatureHelp}{activeSignature} // 0 ;
        }

    return { signatures => \@vars, activeParameter => $argnum + 0, activeSignature => $signum + 0 } ;
    }

# ---------------------------------------------------------------------------

sub _rpcreq_selectionRange
    {
    my ($self, $workspace, $req) = @_ ;

    my $pos = $req -> params -> {position} ;
    my $uri = $req -> params -> {textDocument}{uri} ;
    $self -> logger (pp($req -> params)) ;

    my ($symbol, $offset) = $self -> get_symbol_from_doc ($workspace, $uri, $pos) ;

    $self -> logger ("sym = $symbol, $offset") ;

    return {} ;
    }

# ---------------------------------------------------------------------------

1 ;
