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

Logger log;

static this()
{
	log = createLogger("DAutoTest");
}
