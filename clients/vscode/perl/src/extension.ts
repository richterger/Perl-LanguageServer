
'use strict';

import * as vscode from 'vscode';
import { LanguageClient, LanguageClientOptions, ServerOptions } from 'vscode-languageclient';


// ------------------------------------------------------------------------------

function resolve_workspaceFolder(path: string, resource? : vscode.Uri): string
    {
    if (path.includes("${workspaceFolder}"))
        {
        const ws = vscode.workspace.getWorkspaceFolder(resource as vscode.Uri) ?? vscode.workspace.workspaceFolders?.[0];
        const sub = ws?.uri.fsPath ?? "" ;
        return path.replace("${workspaceFolder}", sub);
        }
    return path;
    }

// ------------------------------------------------------------------------------

function buildContainerArgs (containerCmd: string, containerArgs: string[], containerName: string, containerMode: string): string[]
    {
    //console.log ('buildContainerArgs enter: ' + containerCmd + ' args ' + containerArgs.join (' ') + '  name ' + containerName + ' mode ' + containerMode)  ;

    if (containerMode != 'exec')
        containerMode = 'run' ;

    if (containerCmd)
        {
        if (containerArgs.length == 0)
            {
            if (containerCmd == 'docker')
                {
                containerArgs.push(containerMode) ;
                if (containerMode == 'run')
                    containerArgs.push('--rm') ;
                containerArgs.push('-i', containerName) ;
                }
            else if (containerCmd == 'docker-compose')
                {
                containerArgs.push(containerMode) ;
                if (containerMode == 'run')
                    containerArgs.push('--rm') ;
                containerArgs.push('--no-deps', '-T', containerName) ;
                }
            else if (containerCmd == 'kubectl')
                {
                containerArgs.push('exec', containerName, '-i', '--') ;
                }
            else if (containerCmd == 'devspace')
                {
                containerArgs.push('--silent ', 'enter') ;
                if (containerName)
                    containerArgs.push('-c', containerName) ;
                containerArgs.push('--') ;
                }
            }
        }
    //console.log ('buildContainerArgs exit: ' + containerCmd + ' args ' + containerArgs.join (' ') + '  name ' + containerName + ' mode ' + containerMode)  ;

    return containerArgs ;
    }

// ------------------------------------------------------------------------------

export function activate(context: vscode.ExtensionContext) {

	let config = vscode.workspace.getConfiguration('perl') ;
	if (!config.get('enable'))
		{
		console.log('extension "perl" is disabled');
		return ;
		}

	console.log('extension "perl" is now active');

    let resource = vscode.window.activeTextEditor?.document.uri ;
    let debug_adapter_port : string  = config.get('debugAdapterPort') || '13603' ;
	let perlCmd         : string     = resolve_workspaceFolder((config.get('perlCmd') || 'perl'), resource);
    let perlArgs        : string[]   = config.get('perlArgs') || [] ;
    let perlInc         : string[]   = config.get('perlInc') || [] ;
    let perlIncOpt      : string[]   = perlInc.map((dir: string) => "-I" + resolve_workspaceFolder(dir, resource)) ;
    let env             : any        = config.get('env') || {} ;
	let logFile         : string     = config.get('logFile') || '' ;
    let logLevel        : number     = config.get('logLevel') || 0 ;
    let client_version  : string     = "2.4.0" ;
    let perlArgsOpt     : string[]   = [...perlIncOpt,
                                        ...perlArgs,
                                        '-MPerl::LanguageServer', '-e', 'Perl::LanguageServer::run', '--',
                                        '--port', debug_adapter_port,
                                        '--log-level', logLevel.toString(),
                                        '--log-file',  logFile,
                                        '--version',   client_version] ;

    let sshPortOption = '-p' ;
    let sshCmd : string       = config.get('sshCmd') || '' ;
	if (!sshCmd)
		{
		if (/^win/.test(process.platform))
			{
			sshCmd        = 'plink' ;
            sshPortOption = '-P' ;
            }
		else
			{
			sshCmd = 'ssh' ;
			}
		}
	let sshArgs:string[] = config.get('sshArgs') || [] ;
	let sshUser:string   = config.get('sshUser') || '' ;
	let sshAddr:string   = config.get('sshAddr') || '';
	let sshPort:string   = config.get('sshPort') || '' ;

    let containerCmd  : string   = config.get('containerCmd')  || '' ;
	let containerArgs : string[] = config.get('containerArgs') || [] ;
    let containerName : string   = config.get('containerName') || '' ;
    let containerMode : string   = config.get('containerMode') || 'exec' ;

    let containerArgsOpt : string[] = buildContainerArgs (containerCmd, containerArgs, containerName, containerMode) ;

    var serverCmd : string ;
	var serverArgs : string[] ;

	if (sshAddr && sshUser)
		{
		serverCmd = sshCmd ;
        if (sshPort)
            {
            sshArgs.push(sshPortOption, sshPort) ;
            }
        sshArgs.push('-l', sshUser, sshAddr, '-L', debug_adapter_port + ':127.0.0.1:' + debug_adapter_port) ;
        if (containerCmd)
            {
            sshArgs.push(containerCmd) ;
            sshArgs = sshArgs.concat(containerArgsOpt) ;
            }
        sshArgs.push(perlCmd) ;
        serverArgs = sshArgs.concat(perlArgsOpt) ;
		}
	else
		{
        if (containerCmd)
            {
            serverCmd = containerCmd ;
            serverArgs = containerArgsOpt.concat(perlCmd, perlArgsOpt) ;
            }
        else
            {
		    serverCmd  = perlCmd ;
		    serverArgs = perlArgsOpt ;
            }
		}

    vscode.debug.registerDebugAdapterDescriptorFactory('perl',
        {
        createDebugAdapterDescriptor(session: vscode.DebugSession, executable: vscode.DebugAdapterExecutable)
            {
            let cfg = session.configuration ;

            let debugContainerCmd  : string   = cfg.containerCmd  || containerCmd ;
            let debugContainerArgs : string[] = cfg.containerArgs || containerArgs ;
            let debugContainerName : string   = cfg.containerName || containerName ;
            let debugContainerMode : string   = cfg.containerMode || containerMode ;

            let debugContainerArgsOpt : string[] = buildContainerArgs (debugContainerCmd, debugContainerArgs, debugContainerName, debugContainerMode) ;

            if (debugContainerCmd)
                {
                var daCmd : string ;
                var daArgs : string[] ;

                if (containerCmd)
                    {
                    // LanguageServer already running inside container
                    daArgs = debugContainerArgsOpt.concat ([perlCmd, ...perlIncOpt,
                        ...perlArgs,
                        '-MPerl::LanguageServer::DebuggerBridge', '-e', 'Perl::LanguageServer::DebuggerBridge::run',
                        debug_adapter_port]) ;
                    }
                else
                    {
                    // LanguageServer not running inside container
                    daArgs = debugContainerArgsOpt.concat ([perlCmd, ...perlArgsOpt]) ;
                    }
                daCmd  = debugContainerCmd ;
                console.log ('start perl debug adapter in container: ' + daCmd + ' ' + daArgs.join (' '))  ;
                return new vscode.DebugAdapterExecutable(daCmd, daArgs, { env: env }) ;
                }
            else
                {
                // TODO: use SocketDebugAdapter
                //return new vscode.SocketDebugAdapter () ;

                executable.args.push (debug_adapter_port) ;
                }
            console.log ('start perl debug adapter: ' + executable.command + ' ' + executable.args.join (' '))  ;
            return executable ;
            }
        });

    vscode.debug.registerDebugConfigurationProvider('perl',
        {
        resolveDebugConfiguration(folder: vscode.WorkspaceFolder | undefined, config: vscode.DebugConfiguration, token?: vscode.CancellationToken): vscode.ProviderResult<vscode.DebugConfiguration>
            {
            console.log('start perl debug resolveDebugConfiguration');

            if (!config.request)
                {
                console.log('config perl debug resolveDebugConfiguration');
                var dbgconfig =
                    {
                    type: "perl",
                    request: "launch",
                    name: "Perl-Debug",
                    program: "${workspaceFolder}/${relativeFile}",
                    stopOnEntry: true,
                    reloadModules: true
                    } ;

                return dbgconfig ;
                }

            return config ;
            }
        }, vscode.DebugConfigurationProviderTriggerKind.Dynamic);


	console.log('cmd: ' + serverCmd + ' args: ' + serverArgs.join (' '));

	let debugArgs  = serverArgs.concat(["--debug"]) ;
	let serverOptions: ServerOptions = {
		run:   { command: serverCmd, args: serverArgs, options: { env: env } },
		debug: { command: serverCmd, args: debugArgs,  options: { env: env } },
	} ;

	// Options to control the language client
	let clientOptions: LanguageClientOptions = {
		// Register the server for plain text documents
		documentSelector: [{scheme: 'file', language: 'perl'}],
		synchronize: {
			// Synchronize the setting section 'perl_lang' to the server
			configurationSection: 'perl',
		}
	} ;

	// Create the language client and start the client.
	let disposable = new LanguageClient('perl', 'Perl Language Server', serverOptions, clientOptions).start();

	// Push the disposable to the context's subscriptions so that the
	// client can be deactivated on extension deactivation
	context.subscriptions.push(disposable);
}

// this method is called when your extension is deactivated
export function deactivate() {
}

