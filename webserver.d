import std.algorithm;
import std.array;
import std.conv;
import std.datetime;
import std.exception;
import std.file;
import std.format;
import std.functional;
import std.path;
import std.regex;
import std.string;

import ae.net.asockets;
import ae.net.http.common;
import ae.net.http.responseex;
import ae.net.http.server;
import ae.net.shutdown;
import ae.sys.d.cache;
import ae.sys.file;
import ae.sys.git;
import ae.sys.log;
import ae.utils.array;
import ae.utils.exception;
import ae.utils.meta;
import ae.utils.mime;
import ae.utils.regex;
import ae.utils.sini;
import ae.utils.textout;
import ae.utils.time.format;
import ae.utils.xmllite;

import common;

struct Config
{
	string addr;
	ushort port = 80;
}
immutable Config config;

StringBuffer html;
Logger log;

Repository cache;
Repository.ObjectReader objectReader;

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

		pathSwitch:
		switch (path[0])
		{
			case "":
				title = "Index";
				showIndex();
				break;
			case "history":
				enforce!NotFoundException(path.length == 2, "Bad path");
				auto branch = path[1];
				title = "Branch history - " ~ branch;
				showHistory(branch);
				break;
			case "results":
				title = "Test result";
				enforce!NotFoundException(path.length > 3, "Bad path");
				enforce!NotFoundException(path[1].match(re!`^[0-9a-f]{40}$`), "Bad base commit");
				enforce!NotFoundException(path[2].match(re!`^[0-9a-f]{40}$`) || path[2] == "!base", "Bad pull commit");

				auto testDir = "results/%s/%s/".format(path[1], path[2]);
				enforce!NotFoundException(testDir.exists, "No such commit");

				auto action = path[3];
				switch (action)
				{
					case "":
						showResult(testDir);
						break;
					case "build.log":
						return response.serveText(cast(string)read(pathStr[1..$]));
					case "file":
					{
						auto buildID = readText(testDir ~ "buildid.txt");
						return response.redirect("/artifact/" ~ buildID ~ "/" ~ path[4..$].join("/"));
					}
					case "diff":
					{
						auto buildID = readText(testDir ~ "buildid.txt");
						auto baseBuildID = readText(testDir ~ "../!base/buildid.txt");
						return response.redirect("/diff/" ~ baseBuildID ~ "/" ~ buildID ~ "/" ~ path[4..$].join("/"));
					}
					default:
						throw new NotFoundException("Unknown action");
				}
				break;
			case "artifact":
			{
				enforce!NotFoundException(path.length >= 2, "Bad path");
				auto refName = GitCache.refPrefix ~ path[1];
				auto commitObject = objectReader.read(refName);
				auto obj = objectReader.read(commitObject.parseCommit().tree);
				foreach (dirName; path[2..$])
				{
					auto tree = obj.parseTree();
					if (dirName == "")
					{
						title = "Artifact storage directory listing";
						showDirListing(tree, path.length > 3);
						break pathSwitch;
					}
					auto index = tree.countUntil!(entry => entry.name == dirName);
					enforce!NotFoundException(index >= 0, "Name not in tree: " ~ dirName);
					obj = objectReader.read(tree[index].hash);
				}
				if (obj.type == "tree")
					return response.redirect(path[$-1] ~ "/");
				enforce(obj.type == "blob", "Invalid object type");
				return response.serveData(Data(obj.data), guessMime(path[$-1]));
			}
			case "diff":
			{
				enforce!NotFoundException(path.length >= 4, "Bad path");
				auto refA = GitCache.refPrefix ~ path[1];
				auto refB = GitCache.refPrefix ~ path[2];
				return response.serveText(cache.query(["diff", refA, refB, "--", path[3..$].join("/")]));
			}
			case "static":
				return response.serveFile(pathStr[1..$], "web/");
			case "robots.txt":
				return response.serveText("User-agent: *\nDisallow: /");
			case "webhook":
				if (request.headers.get("X-GitHub-Event", null).isOneOf("push", "pull_request"))
					touch(eventFile);
				return response.serveText("DAutoTest/webserver OK\n");
			default:
				throw new NotFoundException("Unknown resource");
		}
	}
	catch (CaughtException e)
	{
		status = cast(NotFoundException)e ? HttpStatusCode.NotFound : HttpStatusCode.InternalServerError;
		return response.writeError(status, e.toString());
	}

	auto vars = [
		"title" : title,
		"content" : cast(string) html.get(),
	];

	response.serveData(response.loadTemplate("web/skel.htt", vars));
	response.setStatus(status);
	return response;
}

mixin DeclareException!q{NotFoundException};

void showIndex()
{
	html.put(
		"<p>This is the DAutoTest web service.</p>" ~
		`<table>` ~
		`<tr><th>Branch</th><th>Commit</th><th>Status</th></tr>`
	);
	foreach (de; dirEntries("results/!latest", "*.txt", SpanMode.shallow))
	{
		auto name = de.baseName.stripExtension;
		if (name.length == 40)
			continue;
		auto sha = readText(de.name);
		auto resultFn = "results/" ~ sha ~ "/!base/result.txt";
		auto status = resultFn.exists ? resultFn.readText().splitLines()[0] : "-";
		html.put(
			`<tr>` ~
			`<td><a href="/history/`, encodeEntities(name), `">`, encodeEntities(name), `</a></td>` ~
			`<td>`, sha, `</td>` ~
			`<td><a href="/results/`, sha, `/!base/">`, status, `</a></td>` ~
			`</tr>`
		);
	}

	auto currentAction = readText("results/!status.txt").split("\n");
	html.put(
		`</table>` ~

		`<p><b>Current action</b>: `,
			currentAction.get(1, null).length ? `<a href="` ~ currentAction[1] ~`">` : null,
			currentAction.get(0, "Unknown"),
			currentAction.get(1, null).length ? `</a>` : null,
		`</p>`
	);
}

void showHistory(string branch)
{
	Commit*[] commits;
	{
		auto repo = Repository("work/repo");
		auto history = repo.getHistory();
		auto hash = *enforce(("refs/remotes/origin/" ~ branch) in history.refs, "Unknown branch");
		auto commit = history.commits[hash];
		while (commits.length < 100)
		{
			commits ~= commit;
			if (!commit.parents.length)
				break;
			commit = commit.parents[0];
		}
	}

	html.put(
		`<table>` ~
		`<tr>` ~
	//	`<th>Commit</th>` ~
		`<th>Date</th>` ~
		`<th>Title</th>` ~
		`<th>Result</th>` ~
		`</tr>`
	);
	foreach (commit; commits)
	{
		auto sha = commit.hash.toString();
		auto resultFn = "results/" ~ sha ~ "/!base/result.txt";
		auto status = resultFn.exists ? resultFn.readText().splitLines()[0] : "-";

		html.put(
			`<tr>` ~
		//	`<td>`, sha, `</td>` ~
			`<td>`, SysTime.fromUnixTime(commit.time).formatTime!`Y-m-d H:i:s`, `</td>` ~
			`<td>`, encodeEntities(commit.message[0]), `</td>` ~
			`<td><a href="/results/`, sha, `/!base/">`, status, `</a></td>` ~
			`</tr>`
		);
	}
}

void showDirListing(GitObject.TreeEntry[] entries, bool showUpLink)
{
	html.put(
		`<ul class="dirlist">`
	);
	if (showUpLink)
		html.put(
			`<li>       <a href="../">..</a></li>`
		);
	foreach (entry; entries)
	{
		auto name = encodeEntities(entry.name) ~ (entry.mode & octal!40000 ? `/` : ``);
		html.put(
			`<li>`, "%06o".format(entry.mode), ` <a href="`, name, `">`, name, `</a></li>`
		);
	}
	html.put(
		`</ul>`
	);
}

void showResult(string testDir)
{
	string tryReadText(string fileName, string def = null) { return fileName.exists ? fileName.readText : def; }

	auto result = tryReadText(testDir ~ "result.txt").splitLines();
	auto info = tryReadText(testDir ~ "info.txt").splitLines();

	auto base = testDir.split("/")[1];
	auto hash = testDir.split("/")[2];

	html.put(
		`<table>`
	);
	if (hash == "!base")
		html.put(
		`<tr><td>Base commit</td><td>`, base, `</td></tr>`
		);
	else
		html.put(
		`<tr><td>Component</td><td>`, info.get(0, "master"), `</td></tr>` ~
		`<tr><td>Pull request</td><td>`, info.length>2 ? `<a href="` ~ info[2] ~ `">#` ~ info[1] ~ `</a>` : `-`, `</td></tr>` ~
		`<tr><td>Base result</td><td><a href="../!base/">View</a></td></tr>`
		);

	bool success = result.get(0, null) == "success";
	string tentative = success ? `` : ` class="tentative" title="(tentative)"`;
	html.put(
		`<tr><td>Status</td><td>`, result.get(0, "?"), `</td></tr>` ~
		`<tr><td>Details</td><td>`, result.get(1, "?"), `</td></tr>` ~
	//	`<tr><td>Build log</td><td><pre>`, tryReadText(testDir ~ "build.log").encodeEntities(), `</pre></td></tr>`
		`<tr><td>Build log</td><td>`, exists(testDir ~ "build.log") ? `<a href="build.log">View</a>` : "-", `</td></tr>` ~
		`<tr><td>Files</td><td>` ~
			`<a href="file/web/index.html"`, tentative, `>Main page</a> &middot; ` ~
			`<a href="file/web/phobos-prerelease/index.html"`, tentative, `>Phobos</a> &middot; ` ~
			`<a href="file/web/library-prerelease/index.html"`, tentative, `>DDox</a> &middot; ` ~
			`<a href="file/web/"`, tentative, `>All files</a>` ~
		`</td></tr>`
	);
	if (success && exists(testDir ~ "numstat.txt"))
	{
		auto lines = readText(testDir ~ "numstat.txt").strip.splitLines.map!(line => line.split('\t')).array;
		int additions, deletions, maxChanges;
		foreach (line; lines)
		{
			if (line[0] == "-")
				additions++, deletions++;
			else
			{
				additions += line[0].to!int;
				deletions += line[1].to!int;
				maxChanges = max(maxChanges, line[0].to!int + line[1].to!int);
			}
		}

		html.put(`<tr><td>Changes</td><td>`);
		auto changeWidth = min(100.0 / maxChanges, 5.0);
		bool haveChanges = false;
		foreach (line; lines)
		{
			auto fn = line[2];
			if (fileIgnored(fn))
				continue;

			if (!haveChanges)
			{
				html.put(`<table class="changes">`);
				haveChanges = true;
			}
			html.put(`<tr><td>`, encodeEntities(fn), `</td><td>`);
			if (line[0] == "-")
				html.put(`(binary file)`);
			else
			{
				html.put(`<div class="additions" style="width:%5.3f%%" title="%s addition%s"></div>`.format(line[0].to!int * changeWidth, line[0], line[0]=="1" ? "" : "s"));
				html.put(`<div class="deletions" style="width:%5.3f%%" title="%s deletion%s"></div>`.format(line[1].to!int * changeWidth, line[1], line[1]=="1" ? "" : "s"));
			}
			html.put(
				`</td>` ~
				`<td>` ~
					`<a href="../!base/file/`, encodeEntities(fn), `">Old</a> ` ~
					`<a href="file/`, encodeEntities(fn), `">New</a> ` ~
					`<a href="diff/`, encodeEntities(fn), `">Diff</a>` ~
				`</td>` ~
				`</tr>`
			);
		}
		if (haveChanges)
			html.put(`</table>`);
		else
			html.put(`(no changes)`);

		html.put(
			`</td></tr>`
		);
	}
	html.put(
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

version (Posix)
{
	import core.stdc.stdio : fprintf, stderr;
	import core.stdc.signal : signal;
	import core.stdc.stdlib : exit;
	import core.sys.posix.signal : SIGPIPE;

	extern(C) void handle_sigpipe(int signo) nothrow @nogc @system { fprintf(stderr, "SIGPIPE!\n"); exit(1); }

	static this()
	{
		signal(SIGPIPE, &handle_sigpipe);
	}
}

void main()
{
	log = createLogger("WebServer");

	import ae.sys.d.manager : DManager;

	cache = Repository("work/cache-git/v%s/".format(DManager.cacheVersion));
	objectReader = cache.createObjectReader();

	auto server = new HttpServer();
	server.log = log;
	server.handleRequest = toDelegate(&onRequest);
	server.listen(config.port, config.addr);
	addShutdownHandler({ server.close(); });

	socketManager.loop();
}
