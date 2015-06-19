import std.algorithm;

import ae.sys.log;
import ae.utils.sini;

struct Config
{
	string token;
	string[string] env;
	string basePulls;
}

immutable Config config;

shared static this()
{
	config = cast(immutable)
		loadIni!Config("autotest.ini");
}

// ***************************************************************************

void log(string s)
{
	static Logger instance;
	if (!instance)
		instance = createLogger("DAutoTest");
	instance(s);
}

// ***************************************************************************

bool fileIgnored(string fn)
{
	return fn.startsWith("digger-");
}

const eventFile = "pull-pending.txt";
