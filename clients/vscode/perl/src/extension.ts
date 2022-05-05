
'use strict';

import * as vscode from 'vscode';
import { LanguageClient, LanguageClientOptions, ServerOptions } from 'vscode-languageclient';
import getPort, {portNumbers} from './get-port';

export async function activate(context: vscode.ExtensionContext) {

	let config = vscode.workspace.getConfiguration('perl') ;
	if (!config.get('enable'))
		{
		console.log('extension "perl" is disabled');
		return ;
		}

	console.log('extension "perl" is now active');
    let resource = vscode.window.activeTextEditor?.document.uri ;
    let debug_adapter_port : string = (await getPort({port: portNumbers(1025, 65534)}) as Number).toString();
	console.log(`got debug adapter port #${debug_adapter_port}`);
	let perlCmd         : string     = resolve_workspaceFolder((config.get('perlCmd') || 'perl'), resource);
    let perlArgs        : string[]   = config.get('perlArgs') || [] ;
    let perlInc         : string[]   = config.get('perlInc') || [] ;
    let perlIncOpt      : string[]   = perlInc.map((dir: string) => "-I" + resolve_workspaceFolder(dir, resource)) ;
	let logFile         : string     = config.get('logFile') || '' ;
    let logLevel        : number     = config.get('logLevel') || 0 ;
    let client_version  : string     = "2.3.0" ;
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

	var serverCmd : string ;
	var serverArgs : string[] ;

	if (sshAddr && sshUser)
		{
		serverCmd = sshCmd ;
        if (sshPort)
            {
            sshArgs.push(sshPortOption, sshPort) ;
            }
		sshArgs.push('-l', sshUser, sshAddr, '-L', debug_adapter_port + ':127.0.0.1:' + debug_adapter_port, perlCmd) ;
		serverArgs = sshArgs.concat(perlArgsOpt) ;
		}
	else
		{
		serverCmd  = perlCmd ;
		serverArgs = perlArgsOpt ;
		}

    vscode.debug.registerDebugAdapterDescriptorFactory('perl',
        {
        createDebugAdapterDescriptor(session: vscode.DebugSession, executable: vscode.DebugAdapterExecutable)
            {
            executable.args.push (debug_adapter_port) ;
            console.log ('start perl debug adapter: ' + executable.command + ' ' + executable.args.join (' '))  ;
            return executable ;
            }
        });

    /*
    vscode.debug.registerDebugConfigurationProvider('perl',
        {
        provideDebugConfigurations(folder: vscode.WorkspaceFolder | undefined): vscode.ProviderResult<vscode.DebugConfiguration[]>
            {
            console.log('start perl debug provideDebugConfigurations');

            let configs: vscode.DebugConfiguration[] = [];

            var dbgconfig =
                {
                type: "perl",
                request: "launch",
                name: "Perl-Debug",
                program: "${workspaceFolder}/${relativeFile}",
                stopOnEntry: true,
                reloadModules: true
                } ;

            configs.push(dbgconfig);
            return configs ;
            }
        }, vscode.DebugConfigurationProviderTriggerKind.Dynamic);

    */

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
		run:   { command: serverCmd, args: serverArgs },
		debug: { command: serverCmd, args: debugArgs },
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

function resolve_workspaceFolder(path: string, resource? : vscode.Uri): string {
    if (path.includes("${workspaceFolder}")) {
        const ws = vscode.workspace.getWorkspaceFolder(resource as vscode.Uri) ?? vscode.workspace.workspaceFolders?.[0];
        const sub = ws?.uri.fsPath ?? "" ;
        return path.replace("${workspaceFolder}", sub);
    }
    return path;
}