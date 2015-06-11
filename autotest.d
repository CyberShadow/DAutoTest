import core.thread;

import std.conv;
import std.exception;
import std.file;
import std.format;
import std.json;
import std.path;
import std.process;
import std.string;

import ae.net.ssl.openssl;
import ae.sys.net.ae;
import ae.sys.d.manager;
import ae.sys.file;

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

		void buildBase()
		{
			log("Testing base SHA " ~ baseSHA);

			auto testDir = baseTestDir = "results/" ~ baseSHA ~ "/!base";
			log("Test directory: " ~ testDir);
			auto resultFile = testDir ~ "/result.txt";
			resultFile.ensurePathExists();
			if (resultFile.exists)
			{
				auto result = resultFile.readText().splitLines();
				if (result[0] == "success")
				{
					log("Known good base, skipping base test");
					return;
				}
				else
				{
					log("Known bad base");
					baseError = result[1];
				}
			}

			string buildID;

			void setStatus(string status, string description)
			{
				if (buildID)
					write(testDir ~ "/buildid.txt", buildID);
				write(resultFile, "%s\n%s".format(status, description));
			}

			try
			{
				auto state = d.begin("origin/master");

				buildID = d.getComponent("website").getBuildID();
				log("Website build ID: " ~ buildID);

				auto logFile = testDir ~ "/build.log";
				log("Running build (sending output to %s)".format(logFile));
				{
					auto redirected = RedirectOutput(logFile);
					try
						d.build(state, d.config.build);
					catch (Exception e)
					{
						redirected.f.writeln("Build failed: ", e.toString());
						throw new Exception("Build failed");
					}
				}

				setStatus("success", "Base OK");
			}
			catch (Exception e)
			{
				log("Error: " ~ e.toString());
				setStatus("failure", e.msg);
				baseError = e.msg;
			}
		}
		buildBase();
		log(baseError ? "Base is unbuildable!" : "Base OK.");

		foreach (repo; repos)
		{
			auto result = githubQuery("https://api.github.com/repos/D-Programming-Language/" ~ repo ~ "/pulls?per_page=100").parseJSON();

			foreach (pull; result.array)
			{
				Thread.sleep(10.seconds);

				int n = pull["number"].integer.to!int;
				auto sha = pull["head"]["sha"].str;
				auto url = pull["html_url"].str;

				log("Testing %s PR # %d ( %s ), SHA %s".format(repo, n, url, sha));

				auto testDir = "results/" ~ baseSHA ~ "/" ~ sha;
				log("Test directory: " ~ testDir);
				auto resultFile = testDir ~ "/result.txt";
				resultFile.ensurePathExists();
				if (resultFile.exists)
				{
					log("Already tested, skipping");
					continue;
				}

				string buildID;

				void setStatus(string status, string description, string resultDir = null)
				{
					if (url)
						write(testDir ~ "/url.txt", url);
					if (buildID)
						write(testDir ~ "/buildid.txt", buildID);

					if (!resultDir)
						resultDir = testDir;
					auto reply = setTestStatus(repo, sha, n, status, description, "http://dtest.thecybershadow.net/" ~ resultDir ~ "/");
					write(testDir ~ "/ghstatus.json", reply);
					if (status != "pending")
						write(resultFile, "%s\n%s".format(status, description));
				}

				if (baseError)
				{
					setStatus("error", "Git master is not buildable: " ~ baseError, baseTestDir);
					continue;
				}

				string failStatus = "error";

				try
				{
					setStatus("pending", "Building documentation");

					auto state = d.begin(baseSHA);
					log("initial state = " ~ text(state));
					auto pullSHA = d.getPull(repo, n);
					enforce(sha == pullSHA, "Pull request SHA mismatch");
					try
						d.merge(state, repo, pullSHA);
					catch (Exception e)
					{
						log("Merge error: " ~ e.msg);
						throw new Exception("Merge error");
					}

					log("Merge OK, resulting SHA: " ~ state.submoduleCommits[repo]);
					buildID = d.getComponent("website").getBuildID();
					log("Website build ID: " ~ buildID);

					failStatus = "failure";

					auto logFile = testDir ~ "/build.log";
					log("Running build (sending output to %s)".format(logFile));
					{
						auto redirected = RedirectOutput(logFile);
						try
							d.build(state, d.config.build);
						catch (Exception e)
						{
							redirected.f.writeln("Build failed: ", e.toString());
							throw new Exception("Build failed");
						}
					}

					setStatus("success", "Documentation build OK");
				}
				catch (Exception e)
				{
					log("Error: " ~ e.msg);
					setStatus(failStatus, e.msg);
				}
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
			"https://api.github.com/D-Programming-Language/%s/statuses/%s".format(repo, sha),
			[
				"state" : status,
				"target_url" : url,
				"description" : description,
				"context" : "CyberShadow/DAutoTest",
			]
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
