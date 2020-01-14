package Perl::LanguageServer::Methods ;

use Moose::Role ;
use JSON ;

no warnings 'uninitialized' ;

# ---------------------------------------------------------------------------

sub _rpcreq_initialize
    {
    my ($self, $workspace, $req) = @_ ;

    #print STDERR "Call initialize\n" ;

    $Perl::LanguageServer::workspace = Perl::LanguageServer::Workspace -> new ({ config => $req -> params }) ;

    my $caps = 
        {
        # Defines how text documents are synced. Is either a detailed structure defining each notification or
        # for backwards compatibility the TextDocumentSyncKind number. If omitted it defaults to `TextDocumentSyncKind.None`.
        textDocumentSync => 1, # full
        
        # The server provides hover support.
        #hoverProvider?: boolean;
        
        # The server provides completion support.
        #completionProvider?: CompletionOptions;

        # The server provides signature help support.
	    #signatureHelpProvider?: SignatureHelpOptions;

        # The server provides goto definition support.
	    #definitionProvider?: boolean;
        definitionProvider => JSON::true,

        # The server provides Goto Type Definition support.
        # Since 3.6.0
	    #typeDefinitionProvider?: boolean | (TextDocumentRegistrationOptions & StaticRegistrationOptions);

        # The server provides Goto Implementation support.
        # Since 3.6.0
	    #implementationProvider?: boolean | (TextDocumentRegistrationOptions & StaticRegistrationOptions);

        # The server provides find references support.
	    referencesProvider => JSON::true,

        # The server provides document highlight support.
	    #documentHighlightProvider?: boolean;

        # The server provides document symbol support.
	    #documentSymbolProvider?: boolean;
        documentSymbolProvider => JSON::true,

        # The server provides workspace symbol support.
	    workspaceSymbolProvider => JSON::true,

        # The server provides code actions.
	    #codeActionProvider?: boolean;

        # The server provides code lens.
	    #codeLensProvider?: CodeLensOptions;

        # The server provides document formatting.
	    #documentFormattingProvider?: boolean;

        # The server provides document range formatting.
	    #documentRangeFormattingProvider?: boolean;

        # The server provides document formatting on typing.
	    #documentOnTypeFormattingProvider?: DocumentOnTypeFormattingOptions;

        # The server provides rename support.
	    #renameProvider?: boolean;

        # The server provides document link support.
	    #documentLinkProvider?: DocumentLinkOptions;

        # The server provides color provider support.
        # Since 3.6.0
	    #colorProvider?: boolean | ColorProviderOptions | (ColorProviderOptions & TextDocumentRegistrationOptions & StaticRegistrationOptions);

        # The server provides execute command support.
	    #executeCommandProvider?: ExecuteCommandOptions;

        # Workspace specific server capabilities
	    workspace => {
	
	        # The server supports workspace folder.
	        # Since 3.6.0
		    workspaceFolders => {
		
			# The server has support for workspace folders
			supported => JSON::true,
		
			# * Whether the server wants to receive workspace folder
			# * change notifications.
			# *
			# * If a strings is provided the string is treated as a ID
			# * under which the notification is registered on the client
			# * side. The ID can be used to unregister for these events
			# * using the `client/unregisterCapability` request.
			# */
			changeNotifications => JSON::true,
		    }
	    }

        # Experimental server capabilities.
	    #experimental?: any;
        } ;

    return { capabilities => $caps } ;
    }


# ---------------------------------------------------------------------------

sub _rpcnot_initialized
    {
    my ($self, $workspace, $req) = @_ ;

    return if (!$Perl::LanguageServer::client_version) ;

    if ($Perl::LanguageServer::client_version ne $Perl::LanguageServer::VERSION)
        {
        my $msg = "Version of IDE/Editor plugin is $Perl::LanguageServer::client_version\nVersion of Perl::LanguageServer is $Perl::LanguageServer::VERSION\nPlease make sure you run matching versions of the plugin and the Perl::LanguageServer module\nUse 'cpan Perl::LanguageServer' to install the newest version of the Perl::LanguageServer module\n" ;
        $self -> logger ("\n$msg\n") ;
        }
    return ;
    }


# ---------------------------------------------------------------------------

sub _rpcnot_cancelRequest
    {
    my ($self, $workspace, $req) = @_ ;

    my $cancel_id = $req -> params -> {id} ;
    return if (!$cancel_id) ;
    return if (!exists $Perl::LanguageServer::running_req{$cancel_id}) ;
    $Perl::LanguageServer::running_req{$cancel_id} -> cancel_req ;

    return ;
    }

# ---------------------------------------------------------------------------

sub _rpcreq_shutdown
    {
    my ($self, $workspace, $req) = @_ ;

    return if (!$workspace) ;

    $workspace -> shutdown ;
    }

# ---------------------------------------------------------------------------

sub _rpcnot_exit
    {
    my ($self, $workspace, $req) = @_ ;

    print STDERR "Exit\n" ;

    exit (1) if (!$workspace) ;
    exit (1) if (!$workspace -> is_shutdown) ;
    exit (0) ;
    return ;
    }

# ---------------------------------------------------------------------------

1 ;
