
'use strict';

import * as vscode from 'vscode';
import { LanguageClient, LanguageClientOptions, ServerOptions } from 'vscode-languageclient';

export function activate(context: vscode.ExtensionContext) {

	let config = vscode.workspace.getConfiguration('perl') ;
	if (!config.get('enable'))	
		{
		console.log('extension "perl" is disabled');
		return ;
		}

	console.log('extension "perl" is now active');
	
    let debug_adapter_port : string = config.get('debugAdapterPort') || '13603' ; 
	let perlCmd  : string           = config.get('perlCmd') || 'perl' ; 
    let logLevel : number           = config.get('logLevel') || 0 ;
    let client_version : string     = "2.0.1" ;
    let perlArgs : string[]         = ['-MPerl::LanguageServer', '-e', 'Perl::LanguageServer::run', '--', 
                                                                 '--port', debug_adapter_port,
                                                                 '--log-level', logLevel.toString(),
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
		sshArgs.push('-l', sshUser, sshAddr, '-L' + debug_adapter_port + ':127.0.0.1:' + debug_adapter_port, perlCmd) ;
		serverArgs = sshArgs.concat(perlArgs) ;
		}
	else
		{
		serverCmd  = perlCmd ;
		serverArgs = perlArgs ;	
		}	

	/*
	var envStr = '' ;
	let env = config.get('perl_lang.env') || [] ;
	for (var element in env) {
		envStr += ' ' + element+ "='" + env[element] + "'"	;
	}
	*/


    vscode.debug.registerDebugAdapterDescriptorFactory('perl', 
        {
        createDebugAdapterDescriptor(session: vscode.DebugSession, executable: vscode.DebugAdapterExecutable) 
            {
            /*
            console.log('start perl debug server on port ' + debug_adapter_port);
            // make VS Code connect to debug server instead of launching debug adapter
            return new vscode.DebugAdapterServer(parseInt(debug_adapter_port)) ;
            */
            executable.args.push (debug_adapter_port) ;
            console.log ('start perl debug adapter: ' + executable.command + ' ' + executable.args.join (' '))  ;
            return executable ;
            }
        });

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