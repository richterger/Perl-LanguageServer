
'use strict';

import * as vscode from 'vscode';
//import { workspace, ExtensionContext } from 'vscode';
import { LanguageClient, LanguageClientOptions, ServerOptions } from 'vscode-languageclient';

export function activate(context: vscode.ExtensionContext) {

	let config = vscode.workspace.getConfiguration('perl') ;
	if (!config.get('enable'))	
		{
		console.log('extension "perl" is disabled');
		return ;
		}

	console.log('extension "perl" is now active');
	
	let perlCmd : string  = config.get('perlCmd') || 'perl' ; 
	let perlArgs : string[] = ['-MPerl::LanguageServer', '-e', 'Perl::LanguageServer::run', '--'] ;

	let sshCmd : string       = config.get('sshCmd') || '' ; 
	if (!sshCmd)
		{
		if (/^win/.test(process.platform))
			{
			sshCmd = 'plink' ;
			}
		else
			{
			sshCmd = 'ssh' ;
			}
		}
	let sshArgs:string[] = config.get('sshArgs') || [] ;
	let sshUser:string     = config.get('sshUser') || '' ;
	const sshAddr:string     = config.get('sshAddr') || '';
	//const sshPort     = config.get('sshPort') ;

	var serverCmd : string ;
	var serverArgs : string[] ;

	if (sshAddr && sshUser)
		{
		serverCmd = sshCmd ;
		sshArgs.push('-l', sshUser, sshAddr, perlCmd) ;
		serverArgs = sshArgs.concat(perlArgs) ;
		}
	else
		{
		serverCmd = perlCmd ;
		serverArgs = perlArgs ;	
		}	

	/*
	var envStr = '' ;
	let env = config.get('perl_lang.env') || [] ;
	for (var element in env) {
		envStr += ' ' + element+ "='" + env[element] + "'"	;
	}
	*/

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