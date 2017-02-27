import core.thread;

import std.algorithm;
import std.array;
import std.conv;
import std.exception;
import std.file;
import std.format;
import std.json;
import std.path;
import std.process;
import std.stdio : File;
import std.string;

import ae.net.ssl.openssl;
import ae.sys.d.cache;
import ae.sys.log;
import ae.sys.net.ae;
import ae.sys.d.manager;
import ae.sys.file;
import ae.utils.json;
import ae.utils.path : nullFileName;

import common;
import github;

static import std.stdio;

class DTestManager : DManager
{
	override string getCallbackCommand() { assert(false); }
	override void log(string s) { .log(s); }
}

DTestManager d;

const repos = ["dlang.org", "dmd", "druntime", "phobos", "tools"];

void main()
{
	if (quiet)
	{
		auto logFile = File("autotest.log", "wb");
		auto pipes = pipe();
		spawnProcess(["ts", "[%Y-%m-%d %H:%M:%S]"], pipes.readEnd, logFile, logFile);
		std.stdio.stdout = pipes.writeEnd;
		std.stdio.stderr = pipes.writeEnd;
	}

	logAction("Starting");

	d = new DTestManager();
	d.config.local.workDir = "work".absolutePath();
	d.config.local.cache = "git";
	d.config.build.environment = config.env.dup.byPair.assocArray;
	d.autoClean = true;

	foreach (c; d.allComponents)
		d.config.build.components.enable[c] = c == "website";
	d.config.build.components.common.makeArgs = ["-j", "8"];
	d.config.build.components.website.diffable = true;

	while (true)
	{
		logAction("Updating");
		try
			d.update();
		catch (Exception e)
			log("Update error: " ~ e.msg);

		static struct Result
		{
			bool cached;
			string status, description, testDir, buildID;
		}

		Result[string] baseResults;

		Result runBuild(string repo, int n, string sha, string baseSHA)
		{
			auto testDir = "results/" ~ baseSHA ~ "/" ~ (repo ? sha : "!base");
			log("Test directory: " ~ testDir);

			auto resultFile = testDir ~ "/result.txt";
			resultFile.ensurePathExists();

			string buildID;
			auto buildIDFile = testDir ~ "/buildid.txt";
			if (buildIDFile.exists)
				buildID = buildIDFile.readText();

			auto latestFile = "results/!latest/" ~ sha ~ ".txt";
			scope(success)
			{
				ensurePathExists(latestFile);
				write(latestFile, baseSHA);
			}

			if (resultFile.exists)
			{
				auto lines = resultFile.readText().splitLines();
				log("Already tested: %s (%s)".format(lines[0], lines[1]));
				return Result(true, lines[0], lines[1], testDir, buildID);
			}

			Result setStatus(string status, string description)
			{
				if (n)
					write(testDir ~ "/info.txt", "%s\n%d\nhttps://github.com/dlang/%s/pull/%d".format(repo, n, repo, n));
				if (buildID)
					write(buildIDFile, buildID);

				if (repo)
				{
					auto reply = setTestStatus(repo, sha, n, status, description, config.webRoot ~ testDir ~ "/");
					write(testDir ~ "/ghstatus.json", reply);
				}
				if (status != "pending")
					atomicWrite(resultFile, "%s\n%s".format(status, description));
				return Result(false, status, description, testDir, buildID);
			}

			auto baseResult = baseSHA in baseResults;

			//if (baseResult && baseResult.status != "success")
			//	return setStatus("error", "Git master is not buildable: " ~ baseResult.description);

			string failStatus = "error";

			auto logFile = testDir ~ "/build.log";
			try
			{
				log("Sending output to %s".format(logFile));
				auto redirected = RedirectOutput(logFile);

				setStatus("pending", "Building documentation");

				auto state = d.begin(baseSHA);
				log("Repository state: " ~ text(state));

				foreach (basePull; config.basePulls.split(",").map!(to!int))
				{
					log("Fetching additional base pull #%d...".format(basePull));
					auto pullSHA = d.getPull("dlang.org", basePull);

					log("Merging...");
					d.merge(state, "dlang.org", pullSHA);
				}

				if (repo)
				{
					log("Fetching pull...");
					auto pullSHA = d.getPull(repo, n);
					enforce(sha == pullSHA, "Pull request SHA mismatch");

					log("Merging...");
					try
						d.merge(state, repo, pullSHA);
					catch (Exception e)
					{
						log("Merge error: " ~ e.msg);
						throw new Exception("Merge failed");
					}

					log("Merge OK, resulting SHA: " ~ state.submoduleCommits[repo]);
				}

				failStatus = "failure";

				log("Running build");
				{
					try
					{
						scope(exit)
						{
							buildID = d.getComponent("website").getBuildID();
							log("Website build ID: " ~ buildID);
						}

						d.build(state);
					}
					catch (Exception e)
					{
						redirected.f.writeln("Build failed: ", e.toString());
						throw new Exception("Build failed");
					}
				}

				int additions=-1, deletions=-1;

				if (buildID && baseResult && baseResult.buildID)
				{
					auto diffFile = testDir ~ "/numstat.txt";
					if (!diffFile.exists)
					{
						auto r = spawnProcess([
								"git",
								"--git-dir=" ~ d.needCacheEngine().cacheDir ~ "/.git",
								"diff",
								"--numstat",
								GitCache.refPrefix ~ baseResult.buildID,
								GitCache.refPrefix ~ buildID,
							],
							std.stdio.stdin,
							File(diffFile, "wb"),
						).wait();
						if (r == 0)
						{
							additions = deletions = 0;
							foreach (line; diffFile.readText().splitLines().map!(line => line.split("\t")))
								if (line[0] != "-" && !fileIgnored(line[2]))
								{
									additions += line[0].to!int;
									deletions += line[1].to!int;
								}
						}
						else
							diffFile.remove();
					}
				}

				string changes;
				if (additions==-1 && deletions==-1)
					changes = "master build";
				else
				if (!additions && !deletions)
					changes = "no changes";
				else
					changes =
					(
						(additions ? ["%d addition%s".format(additions, additions==1 ? "" : "s")] : [])
						~
						(deletions ? ["%d deletion%s".format(deletions, deletions==1 ? "" : "s")] : [])
					).join(", ");

				return setStatus("success", "Documentation OK (%s)".format(changes));
			}
			catch (Exception e)
			{
				log("Error: " ~ e.msg);
				if (logFile.exists && (cast(string)read(logFile)).indexOf("error: unable to read sha1 file of ") >= 0)
					log("Git corruption detected!");
				return setStatus(failStatus, e.msg);
			}
		}

		logAction("Fetching pulls");

		JSONValue[] pulls;
		foreach (repo; repos)
			pulls ~= githubPagedQuery("https://api.github.com/repos/dlang/" ~ repo ~ "/pulls?per_page=100");

		string lastTest(string sha) { auto fn = "results/!latest/" ~ sha ~ ".txt"; return fn.exists ? fn.readText : null; }
		bool shaTested(string sha) { return lastTest(sha) !is null; }

		logAction("Verifying pulls");

		foreach (pull; pulls)
		{
			auto sha = pull["head"]["sha"].str;
			auto last = lastTest(sha);
			auto dir = "results/" ~ last ~ "/" ~ sha;
			if (last && !exists(dir))
			{
				auto repo = pull["base"]["repo"]["name"].str;
				int n = pull["number"].integer.to!int;
				log(dir ~ " doesn't exist, marking as pending");
				setTestStatus(repo, sha, n, "pending", "Retest pending", null);
				mkdirRecurse(dir);
			}
		}

		logAction("Sorting pulls");

		pulls.multiSort!(
			(a, b) => shaTested(a["head"]["sha"].str) < shaTested(b["head"]["sha"].str),
			(a, b) => a["updated_at"].str > b["updated_at"].str,
		);

		bool foundWork;

		foreach (pull; pulls)
		{
			auto repo = pull["base"]["repo"]["name"].str;
			int n = pull["number"].integer.to!int;
			auto sha = pull["head"]["sha"].str;
			auto url = pull["html_url"].str;

			auto baseBranch = pull["base"]["ref"].str;
			auto baseSHA = d.getMetaRepo().getRef("origin/" ~ baseBranch);

			if (baseSHA !in baseResults)
			{
				logAction("Testing base " ~ baseBranch ~ " SHA " ~ baseSHA, "/results/" ~ baseSHA ~ "/" ~ baseBranch ~ "/");
				auto baseResult = baseResults[baseSHA] = runBuild(null, 0, baseBranch, baseSHA);

				log(baseResult.status == "success" ? "Base OK." : "Base is unbuildable!");
				if (!baseResult.cached)
				{
					foundWork = true;
					break;
				}
			}

			logAction("Testing %s PR # %d ( %s ), updated %s, SHA %s".format(repo, n, url, pull["updated_at"].str, sha), "/results/%s/%s/".format(baseSHA, sha));
			auto last = lastTest(sha);
			if (last)
				log("  (already tested with base SHA %s)".format(last));
			else
				log("  (never tested before)");

			auto result = runBuild(repo, n, sha, baseSHA);
			if (!result.cached)
			{
				foundWork = true;
				break;
			}
		}

		void repackCache(bool full)
		{
			logAction("Running %s artifact store repack".format(full ? "full" : "partial"));
			auto status = spawnProcess([
				"git",
				"--git-dir=" ~ d.needCacheEngine().cacheDir ~ "/.git",
				"repack",
				full ? "-ad" : "-d",
			]).wait();
			enforce(status == 0, "git-repack exited with status %d".format(status));
		}

		static int repackCounter;
		if (!foundWork)
		{
			log("Nothing to do...");
			if (/*repackCounter*/false)
			{
				repackCache(/*true*/false);
				repackCounter = 0;
			}
			else
			{
				logAction("Idling");
				foreach (n; 0..300)
				{
					if (eventFile.exists)
					{
						eventFile.remove();
						log("Activity detected, resuming...");
						break;
					}
					Thread.sleep(1.seconds);
				}
			}
		}
		else
		{
		//	if (repackCounter++ % 10 == 0)
		//		repackCache(false);
		}
	}
}

// Communicate what we're doing right now to the web server
void logAction(string status, string webPath = null)
{
	log(status ~ "...");
	auto statusPath = "results/!status.txt";
	ensurePathExists(statusPath);
	std.file.write(statusPath, status ~ "\n" ~ webPath);
}

string setTestStatus(string repo, string sha, int pull, string status, string description, string url)
{
	log("Setting status for %s pull %s (commit %s) to %s (%s): %s".format(repo, pull, sha, status, description, url));

	debug
		return "OK";
	else
		return githubPost(
			"https://api.github.com/repos/dlang/%s/statuses/%s".format(repo, sha),
			[
				"state" : status,
				"target_url" : url,
				"description" : description,
				"context" : "CyberShadow/DAutoTest",
			].toJson()
		);
}

struct RedirectOutput
{
	import std.stdio;

	File f, oldStdout, oldStderr;

	this(string fn)
	{
		f = File(fn, "wb");
		oldStdout = stdout;
		oldStderr = stderr;
		stdout = f;
		stderr = f;
	}

	~this()
	{
		stdout = oldStdout;
		stderr = oldStderr;
	}

	@disable this(this);
}
