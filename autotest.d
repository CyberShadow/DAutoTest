import core.thread;

import std.algorithm;
import std.conv;
import std.exception;
import std.file;
import std.format;
import std.json;
import std.path;
import std.process;
import std.string;

import ae.net.ssl.openssl;
import ae.sys.d.cache;
import ae.sys.net.ae;
import ae.sys.d.manager;
import ae.sys.file;
import ae.utils.json;

import common;
import github;

class DTestManager : DManager
{
	override string getCallbackCommand() { assert(false); }
	override void log(string s) { .log(s); }
	override void prepareEnv()
	{
		super.prepareEnv();
		foreach (k, v; .config.env)
			if (k == "PATH")
				config.env[k] = config.env[k] ~ pathSeparator ~ v;
			else
				config.env[k] = v;
	}
}

DTestManager d;

const repos = ["dlang.org", "dmd", "druntime", "phobos", "tools"];

void main()
{
	d = new DTestManager();
	d.config.local.workDir = "work".absolutePath();
	d.config.cache = "git";

	foreach (c; d.allComponents)
		d.config.build.components.enable[c] = c == "website";
	d.config.build.components.common.makeArgs = ["-j", "8"];
	d.config.build.components.website.noDateTime = true;

	while (true)
	{
		d.update();

		auto baseSHA = d.getMetaRepo().getRef("origin/master");
		string baseError, baseTestDir;

		static struct Result
		{
			string status, description, testDir, buildID;
		}

		Result runBuild(string repo, int n, string sha, Result* baseResult = null)
		{
			auto testDir = "results/" ~ baseSHA ~ "/" ~ sha;
			log("Test directory: " ~ testDir);
			auto resultFile = testDir ~ "/result.txt";
			auto buildIDFile = testDir ~ "/buildid.txt";
			resultFile.ensurePathExists();
			if (resultFile.exists)
			{
				auto lines = resultFile.readText().splitLines();
				log("Already tested: %s (%s)".format(lines[0], lines[1]));
				return Result(lines[0], lines[1], testDir, buildIDFile.exists ? buildIDFile.readText() : null);
			}

			string buildID;

			Result setStatus(string status, string description, string urlPath = null)
			{
				if (n)
					write(testDir ~ "/info.txt", "%s\n%d\nhttps://github.com/D-Programming-Language/%s/pull/%d".format(repo, n, repo, n));
				if (buildID)
					write(buildIDFile, buildID);

				if (!urlPath)
					urlPath = testDir;
				if (repo)
				{
					auto reply = setTestStatus(repo, sha, n, status, description, "http://dtest.thecybershadow.net/" ~ urlPath ~ "/");
					write(testDir ~ "/ghstatus.json", reply);
				}
				if (status != "pending")
					write(resultFile, "%s\n%s".format(status, description));
				return Result(status, description, testDir, buildID);
			}

			if (baseResult && baseResult.status != "success")
				return setStatus("error", "Git master is not buildable: " ~ baseError, baseTestDir);

			scope(success)
			{
				if (buildID && baseResult && baseResult.buildID)
				{
					auto diffFile = testDir ~ "/diffstat.ansi";
					auto r = spawnProcess([
							"git",
							"--git-dir=" ~ d.cacheEngine.cacheDir ~ "/.git",
							"diff",
							"--stat",
							"--color=always",
							GitCache.refPrefix ~ baseResult.buildID,
							GitCache.refPrefix ~ buildID,
						],
						std.stdio.stdin,
						File(diffFile, "wb"),
					).wait();
					if (r != 0)
						diffFile.remove();
				}
			}

			string failStatus = "error";

			try
			{
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
						throw new Exception("Merge error");
					}

					log("Merge OK, resulting SHA: " ~ state.submoduleCommits[repo]);
				}

				failStatus = "failure";

				auto logFile = testDir ~ "/build.log";
				log("Running build (sending output to %s)".format(logFile));
				{
					auto redirected = RedirectOutput(logFile);
					try
					{
						scope(exit)
						{
							buildID = d.getComponent("website").getBuildID();
							log("Website build ID: " ~ buildID);
						}

						d.build(state, d.config.build);
					}
					catch (Exception e)
					{
						redirected.f.writeln("Build failed: ", e.toString());
						throw new Exception("Build failed");
					}
				}

				return setStatus("success", "Documentation build OK");
			}
			catch (Exception e)
			{
				log("Error: " ~ e.msg);
				return setStatus(failStatus, e.msg);
			}
		}

		log("Testing base SHA " ~ baseSHA);
		auto baseResult = runBuild(null, 0, "!base");
		log(baseResult.status == "success" ? "Base OK." : "Base is unbuildable!");

		foreach (repo; repos)
		{
			auto pulls = githubQuery("https://api.github.com/repos/D-Programming-Language/" ~ repo ~ "/pulls?per_page=100").parseJSON().array;

			foreach (pull; pulls)
			{
				Thread.sleep(10.seconds);

				int n = pull["number"].integer.to!int;
				auto sha = pull["head"]["sha"].str;
				auto url = pull["html_url"].str;

				log("Testing %s PR # %d ( %s ), SHA %s".format(repo, n, url, sha));

				runBuild(repo, n, sha, &baseResult);
			}
		}
	}
}

string setTestStatus(string repo, string sha, int pull, string status, string description, string url)
{
	log("Setting status for %s commit %s to %s (%s): %s".format(repo, pull, status, description, url));

	debug
		return "OK";
	else
		return githubPost(
			"https://api.github.com/repos/D-Programming-Language/%s/statuses/%s".format(repo, sha),
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
