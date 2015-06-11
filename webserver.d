import std.algorithm;
import std.array;
import std.exception;
import std.file;
import std.format;
import std.functional;
import std.regex;
import std.string;

import ae.net.asockets;
import ae.net.http.common;
import ae.net.http.responseex;
import ae.net.http.server;
import ae.net.shutdown;
import ae.sys.log;
import ae.utils.exception;
import ae.utils.meta;
import ae.utils.regex;
import ae.utils.sini;
import ae.utils.textout;
import ae.utils.xmllite;

struct Config
{
	string addr;
	ushort port = 80;
}
immutable Config config;

StringBuffer html;

Logger log;

void onRequest(HttpRequest request, HttpServerConnection conn)
{
	conn.sendResponse(handleRequest(request, conn));
}

HttpResponse handleRequest(HttpRequest request, HttpServerConnection conn)
{
	auto response = new HttpResponseEx();
	auto status = HttpStatusCode.OK;
	string title;
	html.clear();

	try
	{
		auto pathStr = request.resource.findSplit("?")[0];
		enforce(pathStr.startsWith('/'), "Invalid path");
		auto path = pathStr[1..$].split("/");
		if (!path.length) path = [""];

		switch (path[0])
		{
			case "":
				title = "Index";
				showIndex();
				break;
			case "results":
				title = "Test result";
				enforce(path.length >= 3);
				if (path.length == 4 && path[3] == "build.log")
					return response.serveFile(pathStr[1..$], "");
				showResult(path[1], path[2]);
				break;
			case "static":
				return response.serveFile(pathStr[1..$], "web/");
			case "robots.txt":
				return response.serveText("User-agent: *\nDisallow: /");
			default:
				throw new Exception("Unknown resource");
		}
	}
	catch (CaughtException e)
		return response.writeError(HttpStatusCode.InternalServerError, e.toString());

	auto vars = [
		"title" : title,
		"content" : cast(string) html.get(),
	];

	response.serveData(response.loadTemplate("web/skel.htt", vars));
	response.setStatus(status);
	return response;
}

void showIndex()
{
	html.put("This is the DAutoTest web service.");
}

void showResult(string baseCommit, string pullCommit)
{
	enforce(baseCommit.match(re!`^[0-9a-f]{40}$`), "Bad base commit");
	enforce(pullCommit.match(re!`^[0-9a-f]{40}$`) || pullCommit == "!base", "Bad pull commit");
	auto testDir = "results/%s/%s/".format(baseCommit, pullCommit);
	enforce(testDir.exists, "No such commit");

	string tryReadText(string fileName, string def = null) { return fileName.exists ? fileName.readText : def; }

	auto result = tryReadText(testDir ~ "result.txt", "Unknown\n(unknown)").splitLines();
	auto info = tryReadText(testDir ~ "info.txt", "\n0").splitLines();

	html.put(
		`<table>`
		`<tr><td>Component</td><td>`, info[0], `</td></tr>`
		`<tr><td>Pull request</td><td><a href="`, info[2], `">#`, info[1], `</a></td></tr>`
		`<tr><td>Status</td><td>`, result[0], `</td></tr>`
		`<tr><td>Description</td><td>`, result[1], `</td></tr>`
	//	`<tr><td>Build log</td><td><pre>`, tryReadText(testDir ~ "build.log").encodeEntities(), `</pre></td></tr>`
		`<tr><td>Build log</td><td><a href="build.log">View</a></td></tr>`
		`<tr><td>Diff stat</td><td><pre>`, tryReadText(testDir ~ "diffstat.ansi").encodeEntities().ansiToHtml(), `</pre></td></tr>`
		`</table>`
	);
}

string ansiToHtml(string ansi)
{
	return ansi
		.I!(s => `<span>` ~ s ~ `</span>`)
		.replace("\x1B[m"  , `</span><span>`)
		.replace("\x1B[31m", `</span><span class="ansi-1">`)
		.replace("\x1B[32m", `</span><span class="ansi-2">`)
	;
}

shared static this()
{
	config = loadIni!Config("webserver.ini");
}

void main()
{
	log = createLogger("WebServer");

	auto server = new HttpServer();
	server.log = log;
	server.handleRequest = toDelegate(&onRequest);
	server.listen(config.port, config.addr);
	addShutdownHandler({ server.close(); });

	socketManager.loop();
}
