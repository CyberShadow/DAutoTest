import core.thread;

import std.conv;
import std.exception;
import std.file;
import std.format;
import std.json;
import std.path;
import std.process;
import std.stdio;
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

	foreach (c; d.allComponents)
		d.config.build.components.enable[c] = c == "website";
	d.config.build.components.common.makeArgs = ["-j", "8"];

	while (true)
	{
		d.update();

		foreach (repo; repos)
		{
			auto result = githubQuery("https://api.github.com/repos/D-Programming-Language/" ~ repo ~ "/pulls?per_page=100").parseJSON();

			foreach (pull; result.array)
			{
				int n = pull["number"].integer.to!int;
				string failStatus = "error";

				try
				{
					auto sha = pull["head"]["sha"].str;

					log("Testing %s PR # %d (%s), SHA %s".format(repo, n, pull["html_url"].str, sha));

					auto resultFile = "results/" ~ sha;
					if (resultFile.exists)
					{
						log("Already tested, skipping");
						continue;
					}

					setTestStatus(repo, n, "pending", "Building documentation");

					d.getMetaRepo().needRepo();
					auto state = d.begin(d.getMetaRepo().getRef("origin/master"));
					log("initial state = " ~ text(state));
					auto pullSHA = d.getPull(repo, n);
					enforce(sha == pullSHA, "SHA mismatch");
					try
						d.merge(state, repo, pullSHA);
					catch (Exception e)
					{
						log("Merge error: " ~ e.msg);
						throw new Exception("Merge error");
					}

					log("Merge OK, resulting SHA: " ~ state.submoduleCommits[repo]);

					failStatus = "failure";

					auto tempFile = resultFile ~ ".tmp";
					ensurePathExists(tempFile);
					scope(exit) rename(tempFile, resultFile);

					log("Running build (sending output to %s)".format(resultFile));
					{
						auto redirected = RedirectOutput(tempFile);
						d.build(state, d.config.build);
					}

					setTestStatus(repo, n, "success", "Documentation build OK");
					
				}
				catch (Exception e)
				{
					log("Error: " ~ e.toString());
					setTestStatus(repo, n, failStatus, e.msg);
					Thread.sleep(10.seconds);
				}
			}
		}
	}
}

void setTestStatus(string repo, int pull, string status, string description)
{
	log("Setting status for %s PR # %d to %s (%s)".format(repo, pull, status, description));

	// TODO: ping GH
}

struct RedirectOutput
{
	File oldStdout, oldStderr;

	this(string fn)
	{
		File f = File(fn, "wb");
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
