package Perl::LanguageServer::Methods::DebugAdapter ;

use Moose::Role ;

use Coro ;
use Coro::AIO ;
use Data::Dump qw{dump pp} ;
use Perl::LanguageServer::DevTool ;
use Perl::LanguageServer::DebuggerProcess ;

no warnings 'uninitialized' ;

our %debug_adapters ;

# ---------------------------------------------------------------------------

has 'debugger_process' =>
    (
    isa => 'Perl::LanguageServer::DebuggerProcess',
    is  => 'rw'
    ) ;

has 'debug_adapter_interface' =>
    (
    isa => 'Perl::LanguageServer',
    is  => 'rw',
    weak_ref => 1,
    ) ;

has 'ref2id' =>
    (
    isa => 'HashRef',
    is  => 'rw',
    default => sub { {} },
    ) ;

has 'id2ref' =>
    (
    isa => 'HashRef',
    is  => 'rw',
    default => sub { {} },
    ) ;

has 'refcnt' =>
    (
    isa => 'Int',
    is  => 'rw',
    default => 1,
    ) ;

has 'running' =>
    (
    isa => 'Int',
    is  => 'rw',
    default => 0,
    ) ;

has 'in_temp_break' =>
    (
    isa => 'Int',
    is  => 'rw',
    default => 0,
    ) ;

# ---------------------------------------------------------------------------

sub getid
    {
    my ($self, $parentid, $ref, $param) = @_ ;

    my $refs = $self -> ref2id ;
    my $ndx = $parentid . ':' . $ref ;

    return $refs -> {$ndx} + 0 if (exists $refs -> {$ndx}) ;

    my $refcnt = $self -> refcnt ;
    $self -> id2ref -> {$refcnt} = { ref => $ref, ($param?%$param:()) } ;
    $refs -> {$ndx} = $refcnt+0 ;
    $refcnt++ ;
    return $self -> refcnt ($refcnt) - 1 ; # make sure there is no string value, so encode json encodes it as number
    }

# ---------------------------------------------------------------------------

sub clear_non_thread_ids
    {
    my ($self) = @_ ;

    my $refs = $self -> ref2id ;
    my $id2refs = $self -> id2ref ;
    my $id ;
    foreach (keys %$refs)
        {
        if (/^0:/)
            {
            $id = delete $refs -> {$_} ;
            delete $id2refs -> {$id} ;
            }
        }
    }

# ---------------------------------------------------------------------------

sub send_event
    {
    my ($self, $event, $body) = @_ ;

    $self -> send_notification ({ type => 'event', event => $event, body => $body }, $self) ;
    }

# ---------------------------------------------------------------------------

sub send_request
    {
    my ($self, $command, $body) = @_ ;

    return $self -> debug_adapter_interface -> request ({ command => $command, $body?%$body:() }) ;
    }


# ---------------------------------------------------------------------------


sub _dapreq_initialize
    {
    my ($self, $workspace, $req) = @_ ;

    $self -> log_prefix ('DA') ;

    $Perl::LanguageServer::dev_tool    = Perl::LanguageServer::DevTool -> new ({ config => $req -> params }) ;
    $Perl::LanguageServer::workspace ||= Perl::LanguageServer::Workspace -> new ({ config =>{} }) ;

    #$self -> logger ('initialize debug adapter', dump ($req -> params),"\n") ;

    my $caps =
        {
        # The debug adapter supports the 'configurationDone' request.
        supportsConfigurationDoneRequest => JSON::true(),

        # The debug adapter supports function breakpoints.
        supportsFunctionBreakpoints => JSON::false(),

        # The debug adapter supports conditional breakpoints.
        supportsConditionalBreakpoints => JSON::true(),

        # The debug adapter supports breakpoints that break execution after a specified number of hits.
        supportsHitConditionalBreakpoints => JSON::false(),

        # The debug adapter supports a (side effect free) evaluate request for data hovers.
        supportsEvaluateForHovers => JSON::true(),

        # Available filters or options for the setExceptionBreakpoints request.
        exceptionBreakpointFilters => [],

        # The debug adapter supports stepping back via the 'stepBack' and 'reverseContinue' requests.
        supportsStepBack => JSON::false(),

        # The debug adapter supports setting a variable to a value.
        supportsSetVariable => JSON::true(),

        # The debug adapter supports restarting a frame.
        supportsRestartFrame => JSON::false(),

        # The debug adapter supports the 'gotoTargets' request.
        supportsGotoTargetsRequest => JSON::false(),

        # The debug adapter supports the 'stepInTargets' request.
        supportsStepInTargetsRequest => JSON::false(),

        # The debug adapter supports the 'completions' request.
        supportsCompletionsRequest => JSON::false(),

        # The set of characters that should trigger completion in a REPL. If not specified, the UI should assume the '.' character.
        completionTriggerCharacters => [],

        # The debug adapter supports the 'modules' request.
        supportsModulesRequest => JSON::true(),

        # The set of additional module information exposed by the debug adapter.
        additionalModuleColumns => [],

        # Checksum algorithms supported by the debug adapter.
        supportedChecksumAlgorithms => [],

        # The debug adapter supports the 'restart' request. In this case a client should not implement 'restart' by terminating and relaunching the adapter but by calling the RestartRequest.
        supportsRestartRequest => JSON::false(),

        # The debug adapter supports 'exceptionOptions' on the setExceptionBreakpoints request.
        supportsExceptionOptions => JSON::false(),

        # The debug adapter supports a 'format' attribute on the stackTraceRequest, variablesRequest, and evaluateRequest.
        supportsValueFormattingOptions => JSON::false(),

        # The debug adapter supports the 'exceptionInfo' request.
        supportsExceptionInfoRequest => JSON::false(),

        # The debug adapter supports the 'terminateDebuggee' attribute on the 'disconnect' request.
        supportTerminateDebuggee => JSON::true(),

        # The debug adapter supports the delayed loading of parts of the stack, which requires that both the 'startFrame' and 'levels' arguments and the 'totalFrames' result of the 'StackTrace' request are supported.
        supportsDelayedStackTraceLoading => JSON::true(),

        # The debug adapter supports the 'loadedSources' request.
        supportsLoadedSourcesRequest => JSON::true(),

        # The debug adapter supports logpoints by interpreting the 'logMessage' attribute of the SourceBreakpoint.
        supportsLogPoints => JSON::false(),

        # The debug adapter supports the 'terminateThreads' request.
        supportsTerminateThreadsRequest => JSON::true(),

        # The debug adapter supports the 'setExpression' request.
        supportsSetExpression => JSON::true(),

        # The debug adapter supports the 'terminate' request.
        supportsTerminateRequest => JSON::true(),

        # The debug adapter supports data breakpoints.
        supportsDataBreakpoints => JSON::false(),

        # The debug adapter supports the 'readMemory' request.
        supportsReadMemoryRequest => JSON::false(),

        # The debug adapter supports the 'disassemble' request.
        supportsDisassembleRequest => JSON::false(),

        # The debug adapter supports the 'cancel' request.
        supportsCancelRequest => JSON::true(),

        # The debug adapter supports the 'breakpointLocations' request.
        supportsBreakpointLocationsRequest => JSON::true(),
        } ;

    return $caps ;
    }

# ---------------------------------------------------------------------------

sub _check_not_running
    {
    my ($self, $workspace) = @_ ;

    if ($self -> running)
        {
        die "Debuggee is running" ;
        }
    return ;
    }

# ---------------------------------------------------------------------------

sub _temp_break
    {
    my ($self, $workspace) = @_ ;

    my $running = $self -> running ;
    return if (!$running) ;

    my $temp_break_guard = Guard::guard
        {
        $self -> _temp_cont ($workspace, $running) ;
        } ;

    my $cnt = 50 ;
    my $itb = $self -> in_temp_break ;
    $self -> in_temp_break ($itb + 1) ;
    $self -> logger ("in_temp_break = ", $itb + 1, "\n") ;
    $self -> _dapreq_pause ($workspace) if ($itb == 0);
    while ($self -> running && $cnt-- > 0)
        {
        Coro::AnyEvent::sleep (0.1) ;
        }
    $self -> _check_not_running ($workspace) ;
    $running = 0 if (!$self -> in_temp_break) ;

    return $temp_break_guard ;
    }

# ---------------------------------------------------------------------------

sub _temp_cont
    {
    my ($self, $workspace, $old_running) = @_ ;

    my $itb = $self -> in_temp_break ;
    $self -> logger ("temp_cont = $itb old_running = $old_running\n") ;
    return if (!$old_running) ;
    return if ($itb == 0) ;
    $self -> in_temp_break ($itb - 1) ;
    if ($itb == 1)
        {
        $self -> running (1) ;
        $self -> send_request ('continue') ;
        }
    }


# ---------------------------------------------------------------------------

sub _set_breakpoints
    {
    my ($self, $workspace, $req, $location, $breakpoints, $source) = @_ ;

    my $temp_break_guard = $self -> _temp_break ($workspace) ;

    my @bp ;
    for (my $i; $i < @$breakpoints; $i++)
        {
        push @bp, [$breakpoints -> [$i]{$location}, $breakpoints -> [$i]{condition}]
        }

    my $ret = $self -> send_request ('breakpoint',
                                        {
                                        breakpoints => \@bp,
                                        ($source?(filename    => $self -> debugger_process -> file_client2server ($workspace, $source -> {path})):()),
                                        }) ;

    if ($req -> params -> {real_filename})
        {
        $workspace -> add_path_mapping ($req -> params -> {real_filename}, $self -> debugger_process -> file_server2client ($workspace, $req -> params -> {req_filename}))
        }

    my @setbp ;
    for (my $i; $i < @{$ret -> {breakpoints}}; $i++)
        {
        my $bp = $ret -> {breakpoints}[$i] ;
        push @setbp,
            {
            verified => $bp -> [2]?JSON::true ():JSON::false (),
            message  => $bp -> [3],
            line     => $bp -> [4]+0,
            id       => $bp -> [6]+0,
            source   => { path => $self -> debugger_process -> file_server2client ($workspace, $bp -> [5]) },
            }
        }

    return { breakpoints => \@setbp } ;
    }

# ---------------------------------------------------------------------------

sub _dapreq_setBreakpoints
    {
    my ($self, $workspace, $req) = @_ ;

    my $breakpoints = $req -> params -> {breakpoints} ;
    my $source      = $req -> params -> {source} ;

    return { breakpoints => [] } if (!$breakpoints || !$source);

    return $self -> _set_breakpoints ($workspace, $req, 'line', $breakpoints, $source) ;
    }

# ---------------------------------------------------------------------------

sub _dapreq_setFunctionBreakpoints
    {
    my ($self, $workspace, $req) = @_ ;

    my $breakpoints = $req -> params -> {breakpoints} ;

    return { breakpoints => [] } if (!$breakpoints);

    return $self -> _set_breakpoints ($workspace, $req, 'name', $breakpoints) ;
    }

# ---------------------------------------------------------------------------

sub _dapreq_setExceptionBreakpoints
    {
    my ($self, $workspace, $req) = @_ ;

    return {} ;
    }

# ---------------------------------------------------------------------------

sub _dapreq_breakpointLocations
    {
    my ($self, $workspace, $req) = @_ ;

    my $dai = $self -> debug_adapter_interface ;
    return { breakpoints => [] } if (!$dai || !$dai -> initialized) ;

    my $temp_break_guard = $self -> _temp_break ($workspace) ;

    my $source      = $req -> params -> {source} ;
    my $ret = $self -> send_request ('can_break',
                                        {
                                        line => $req -> params -> {line},
                                        end_line => $req -> params -> {endLine},
                                        ($source?(filename    => $self -> debugger_process -> file_client2server ($workspace, $source -> {path})):()),
                                        }) ;

    foreach (@{$ret -> {breakpoints}})
        {
        $_ -> {line} += 0 ;
        }

    return $ret ;
    }

# ---------------------------------------------------------------------------

sub _dapreq_configurationDone
    {
    my ($self, $workspace, $req) = @_ ;

    if (!$self -> debugger_process -> stop_on_entry)
        {
        $self -> running (1) ;
        $self -> send_request ('continue') ;
        $self -> send_event ('continued', { allThreadsContinued => JSON::true() }) ;
        }

    return {} ;
    }

# ---------------------------------------------------------------------------

sub _dapreq_launch
    {
    my ($self, $workspace, $req) = @_ ;

    $self -> _check_not_running ($workspace) ;

    $self -> running (1) ;
    my $proc = Perl::LanguageServer::DebuggerProcess -> new ($req -> params) ;
    $self -> debugger_process ($proc) ;
    $proc -> debug_adapter ($self) ;
    $debug_adapters{$proc -> session_id} = $self ;
    $proc -> launch ($workspace, $workspace -> perlcmd) ;

    return {} ;
    }

# ---------------------------------------------------------------------------

sub _dapreq_loadedSources
    {
    my ($self, $workspace, $req) = @_ ;

    my @sources = ( { path => $self -> debugger_process -> program });
    return { sources => \@sources } ;
    }

# ---------------------------------------------------------------------------

sub _dapreq_threads
    {
    my ($self, $workspace, $req) = @_ ;

    $self -> _check_not_running ($workspace) ;

    my $threads = $self -> send_request ('threads') ;
    foreach (@{$threads -> {threads}})
        {
        $_ -> {id} = $self -> getid (0, $_ -> {thread_ref}) ;
        }

    return $threads ;
    }

# ---------------------------------------------------------------------------

sub _dapreq_stackTrace
    {
    my ($self, $workspace, $req) = @_ ;

    $self -> _check_not_running ($workspace) ;

    my $thread_ref = $self -> id2ref -> {$req -> params -> {threadId}} -> {ref} ;
    my $frames = $self -> send_request ('stack',
                                        {
                                        thread_ref => $thread_ref,
                                        levels     => $req -> params -> {levels},
                                        start      => $req -> params -> {startFrame},
                                        }) ;

    foreach (@{$frames -> {stackFrames}})
        {
        $_ -> {id}      = $self -> getid ($req -> params -> {threadId}, $_ -> {frame_ref}, { thread_ref => $thread_ref, package => $_ -> {'package'} }) ;
        $_ -> {line}   += 0 ;
        $_ -> {column} += 0 ;
        $_ -> {source}{path} = $self -> debugger_process -> file_server2client ($workspace, $_ -> {source}{path}) ;
        }

    return $frames ;
    }

# ---------------------------------------------------------------------------

sub _dapreq_scopes
    {
    my ($self, $workspace, $req) = @_ ;

    $self -> _check_not_running ($workspace) ;

    my $ref        = $self -> id2ref -> {$req -> params -> {frameId}} ;
    my $frame_ref  = $ref -> {ref} ;
    my $thread_ref = $ref -> {thread_ref} ;
    my $package    = $ref -> {package} ;

    return
        {
        scopes =>
            [
            { name => 'Locals',    presentationHint => 'locals', expensive => JSON::false (),
                variablesReference => $self -> getid ($req -> params -> {frameId}, 'l', { frame_ref => $frame_ref, thread_ref => $thread_ref, package => $package }),  },
            { name => 'Globals',    presentationHint => 'globals', expensive => JSON::true (),
                variablesReference => $self -> getid ($req -> params -> {frameId}, 'g', { frame_ref => $frame_ref, thread_ref => $thread_ref, package => $package }),  },
            { name => 'Specials',    presentationHint => 'specials', expensive => JSON::true (),
                variablesReference => $self -> getid ($req -> params -> {frameId}, 's', { frame_ref => $frame_ref, thread_ref => $thread_ref, package => $package }),  },
            { name => 'Arguments',    presentationHint => 'arguments', expensive => JSON::true (),
                variablesReference => $self -> getid ($req -> params -> {frameId}, 'a', { frame_ref => $frame_ref, thread_ref => $thread_ref, package => $package }),  },
            ]
        }    ;
    }

# ---------------------------------------------------------------------------

sub _dapreq_variables
    {
    my ($self, $workspace, $req) = @_ ;

    $self -> _check_not_running ($workspace) ;

    my $params     = $req -> params ;
    my $ref        = $self -> id2ref -> {$params -> {variablesReference}} ;
    my $frame_ref  = $ref -> {frame_ref} ;
    my $thread_ref = $ref -> {thread_ref} ;
    my $package    = $ref -> {package} ;
    my $type       = $ref -> {ref} ;
    #use Data::Dump ;
    #print STDERR Data::Dump::pp($self -> id2ref), "\n" ;
    my $variables = $self -> send_request ('vars',
                                        {
                                        thread_ref => $thread_ref,
                                        frame_ref  => $frame_ref,
                                        'package'  => $package,
                                        type       => $type,
                                        #var_ref    => $ref,
                                        count      => $params -> {count},
                                        start      => $params -> {start},
                                        filter     => $params -> {filter},
                                        }) ;

    foreach (@{$variables -> {variables}})
        {
        $_ -> {variablesReference} = $_ -> {var_ref}?$self -> getid ($req -> params -> {variablesReference},
                                                                     $_ -> {var_ref},
                                                                        {
                                                                        frame_ref  => $frame_ref,
                                                                        thread_ref => $thread_ref,
                                                                        'package'  => $package,
                                                                         type      => $type}):
                                                    0 ;
        $_ -> {name} .= '' ; # make sure name is a string, otherwise array indices fails on mac
        }

    return $variables ;
    }

# ---------------------------------------------------------------------------

sub _dapreq_setVariable
    {
    my ($self, $workspace, $req) = @_ ;

    $self -> _check_not_running ($workspace) ;

    my $params     = $req -> params ;
    my $ref        = $self -> id2ref -> {$params -> {variablesReference}} ;
    my $frame_ref  = $ref -> {frame_ref} ;
    my $thread_ref = $ref -> {thread_ref} ;
    my $package    = $ref -> {package} ;
    my $type       = $ref -> {ref} ;
    my $expr       = $params->{value} ;
    my $setvar     = $params->{name} ;

    my $result = $self -> send_request ('setvar',
                                        {
                                        thread_ref => $thread_ref,
                                        frame_ref  => $frame_ref,
                                        'package'  => $package,
                                        expression => $expr,
                                        type       => $type,
                                        setvar     => $setvar,
                                        }) ;

    $result -> {variablesReference} = $result -> {var_ref}?$self -> getid ($req -> params -> {variablesReference},
                                                                    $result -> {var_ref},
                                                                    {
                                                                    frame_ref  => $frame_ref,
                                                                    thread_ref => $thread_ref,
                                                                    'package'  => $package,
                                                                    }):
                                                0 ;
    return $result ;
    }


# ---------------------------------------------------------------------------

sub _dapreq_source
    {
    my ($self, $workspace, $req) = @_ ;
    
    my $source      = $req -> params -> {source} ;
    $self -> logger ("req_source source =" . pp($source)) ;
    my $ret = $self -> send_request ('source',
                                        {
                                        ($source?(filename    => $self -> debugger_process -> file_client2server ($workspace, $source -> {path})):()),
                                        }) ;
    $self -> logger ("_dapreq_source ret = " . pp($ret)) ;
    return $ret;
    }

# ---------------------------------------------------------------------------

sub _dapreq_evaluate
    {
    my ($self, $workspace, $req) = @_ ;

    $self -> _check_not_running ($workspace) ;

    my $ref        = $self -> id2ref -> {$req -> params -> {frameId}} ;
    my $frame_ref  = $ref -> {ref} ;
    my $thread_ref = $ref -> {thread_ref} ;
    my $package    = $ref -> {package} ;


    my $result = $self -> send_request ('evaluate',
                                        {
                                        thread_ref => $thread_ref,
                                        frame_ref  => $frame_ref,
                                        'package'  => $package,
                                        expression     => $req -> params -> {expression},
                                        context      => $req -> params -> {context},
                                        }) ;

    $result -> {variablesReference} = $result -> {var_ref}?$self -> getid ($req -> params -> {variablesReference},
                                                                    $result -> {var_ref},
                                                                    {
                                                                    frame_ref  => $frame_ref,
                                                                    thread_ref => $thread_ref,
                                                                    'package'  => $package,
                                                                    }):
                                                0 ;
    $result -> {result} = delete $result -> {value} ;
    return $result ;
    }

# ---------------------------------------------------------------------------

sub _dapreq_pause
    {
    my ($self, $workspace, $req) = @_ ;

    $self -> logger ("send SIGINT for pause\n") ;
    $self -> debugger_process -> signal ('INT') ;

    return {} ;
    }

# ---------------------------------------------------------------------------

sub _dapreq_terminate
    {
    my ($self, $workspace, $req) = @_ ;

    $self -> debugger_process -> signal ('TERM') ;

    return {} ;
    }

# ---------------------------------------------------------------------------

sub _dapreq_disconnect
    {
    my ($self, $workspace, $req) = @_ ;

    $self -> debugger_process -> signal ('KILL') ;

    return {} ;
    }

# ---------------------------------------------------------------------------

sub _dapreq_continue
    {
    my ($self, $workspace, $req) = @_ ;

    $self -> _check_not_running ($workspace) ;

    $self -> running (1) ;
    $self -> send_request ('continue', $req?{ thread_id => $req -> {threadId}}:undef) ;

    return {} ;
    }

# ---------------------------------------------------------------------------

sub _dapreq_stepIn
    {
    my ($self, $workspace, $req) = @_ ;

    $self -> _check_not_running ($workspace) ;

    $self -> running (1) ;
    $self -> send_request ('step_in', { thread_id => $req -> {threadId}}) ;

    return {} ;
    }

# ---------------------------------------------------------------------------

sub _dapreq_stepOut
    {
    my ($self, $workspace, $req) = @_ ;

    $self -> _check_not_running ($workspace) ;

    $self -> running (1) ;
    $self -> send_request ('step_out', { thread_id => $req -> {threadId}}) ;

    return {} ;
    }

# ---------------------------------------------------------------------------

sub _dapreq_next
    {
    my ($self, $workspace, $req) = @_ ;

    $self -> _check_not_running ($workspace) ;

    $self -> running (1) ;
    $self -> send_request ('next', { thread_id => $req -> {threadId}}) ;

    return {} ;
    }


1 ;
