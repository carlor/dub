/**
	Management of packages on the local computer.

	Copyright: © 2012 rejectedsoftware e.K.
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig, Matthias Dondorff
*/
module dub.packagemanager;

import dub.dependency;
import dub.installation;
import dub.internal.vibecompat.core.file;
import dub.internal.vibecompat.core.log;
import dub.internal.vibecompat.data.json;
import dub.internal.vibecompat.inet.path;
import dub.package_;
import dub.utils;

import std.algorithm : countUntil, filter, sort, canFind;
import std.array;
import std.conv;
import std.digest.sha;
import std.encoding : sanitize;
import std.exception;
import std.file;
import std.string;
import std.zip;


enum JournalJsonFilename = "journal.json";
enum LocalPackagesFilename = "local-packages.json";


private struct Repository {
	Path path;
	Path packagePath;
	Path[] searchPath;
	Package[] localPackages;

	this(Path path)
	{
		this.path = path;
		this.packagePath = path ~"packages/";
	}
}

enum LocalPackageType {
	user,
	system
}


class PackageManager {
	private {
		Repository[LocalPackageType] m_repositories;
		Path[] m_searchPath;
		Package[][string] m_packages;
		Package[] m_temporaryPackages;
	}

	this(Path user_path, Path system_path)
	{
		m_repositories[LocalPackageType.user] = Repository(user_path);
		m_repositories[LocalPackageType.system] = Repository(system_path);
		refresh(true);
	}

	@property void searchPath(Path[] paths) { m_searchPath = paths.dup; refresh(false); }
	@property const(Path)[] searchPath() const { return m_searchPath; }

	@property const(Path)[] completeSearchPath()
	const {
		auto ret = appender!(Path[])();
		ret.put(m_searchPath);
		ret.put(m_repositories[LocalPackageType.user].searchPath);
		ret.put(m_repositories[LocalPackageType.user].packagePath);
		ret.put(m_repositories[LocalPackageType.system].searchPath);
		ret.put(m_repositories[LocalPackageType.system].packagePath);
		return ret.data;
	}

	Package getPackage(string name, Version ver)
	{
		foreach( p; getPackageIterator(name) )
			if( p.ver == ver )
				return p;
		return null;
	}

	Package getPackage(string name, string ver, Path in_path)
	{
		return getPackage(name, Version(ver), in_path);
	}
	Package getPackage(string name, Version ver, Path in_path)
	{
		foreach( p; getPackageIterator(name) )
			if (p.ver == ver && p.path.startsWith(in_path))
				return p;
		return null;
	}

	Package getPackage(string name, string ver)
	{
		foreach (ep; getPackageIterator(name)) {
			if (ep.vers == ver)
				return ep;
		}
		return null;
	}

	Package getPackage(Path path)
	{
		foreach (p; getPackageIterator())
			if (!p.basePackage && p.path == path)
				return p;
		auto p = new Package(path);
		m_temporaryPackages ~= p;
		return p;
	}

	Package getBestPackage(string name, string version_spec)
	{
		return getBestPackage(name, Dependency(version_spec));
	}

	Package getBestPackage(string name, Dependency version_spec)
	{
		Package ret;
		foreach( p; getPackageIterator(name) )
			if( version_spec.matches(p.ver) && (!ret || p.ver > ret.ver) )
				ret = p;
		return ret;
	}

	int delegate(int delegate(ref Package)) getPackageIterator()
	{
		int iterator(int delegate(ref Package) del)
		{
			int handlePackage(Package p) {
				if (auto ret = del(p)) return ret;
				foreach (sp; p.subPackages)
					if (auto ret = del(sp))
						return ret;
				return 0;
			}

			foreach (tp; m_temporaryPackages)
				if (auto ret = handlePackage(tp)) return ret;

			// first search local packages
			foreach (tp; LocalPackageType.min .. LocalPackageType.max+1)
				foreach (p; m_repositories[cast(LocalPackageType)tp].localPackages)
					if (auto ret = handlePackage(p)) return ret;

			// and then all packages gathered from the search path
			foreach( pl; m_packages )
				foreach( v; pl )
					if( auto ret = handlePackage(v) )
						return ret;
			return 0;
		}

		return &iterator;
	}

	int delegate(int delegate(ref Package)) getPackageIterator(string name)
	{
		int iterator(int delegate(ref Package) del)
		{
			foreach (p; getPackageIterator())
				if (p.name == name)
					if (auto ret = del(p)) return ret;
			return 0;
		}

		return &iterator;
	}

	Package install(Path zip_file_path, Json package_info, Path destination)
	{
		auto package_name = package_info.name.get!string();
		auto package_version = package_info["version"].get!string();
		auto clean_package_version = package_version[package_version.startsWith("~") ? 1 : 0 .. $];

		logDiagnostic("Installing package '%s' version '%s' to location '%s' from file '%s'", 
			package_name, package_version, destination.toNativeString(), zip_file_path.toNativeString());

		if( existsFile(destination) ){
			throw new Exception(format("%s %s needs to be uninstalled prior installation.", package_name, package_version));
		}

		// open zip file
		ZipArchive archive;
		{
			logDebug("Opening file %s", zip_file_path);
			auto f = openFile(zip_file_path, FileMode.Read);
			scope(exit) f.close();
			archive = new ZipArchive(f.readAll());
		}

		logDebug("Installing from zip.");

		// In a github zip, the actual contents are in a subfolder
		Path zip_prefix;
		foreach(ArchiveMember am; archive.directory) {
			if( Path(am.name).head == PathEntry(PackageJsonFilename) ){
				zip_prefix = Path(am.name)[0 .. 1];
				break;
			}
		}

		if( zip_prefix.empty ){
			// not correct zip packages HACK
			Path minPath;
			foreach(ArchiveMember am; archive.directory)
				if( isPathFromZip(am.name) && (minPath == Path() || minPath.startsWith(Path(am.name))) )
					zip_prefix = Path(am.name);
		}

		logDebug("zip root folder: %s", zip_prefix);

		Path getCleanedPath(string fileName) {
			auto path = Path(fileName);
			if(zip_prefix != Path() && !path.startsWith(zip_prefix)) return Path();
			return path[zip_prefix.length..path.length];
		}

		// install
		mkdirRecurse(destination.toNativeString());
		auto journal = new Journal;
		logDiagnostic("Copying all files...");
		int countFiles = 0;
		foreach(ArchiveMember a; archive.directory) {
			auto cleanedPath = getCleanedPath(a.name);
			if(cleanedPath.empty) continue;
			auto dst_path = destination~cleanedPath;

			logDebug("Creating %s", cleanedPath);
			if( dst_path.endsWithSlash ){
				if( !existsDirectory(dst_path) )
					mkdirRecurse(dst_path.toNativeString());
				journal.add(Journal.Entry(Journal.Type.Directory, cleanedPath));
			} else {
				if( !existsDirectory(dst_path.parentPath) )
					mkdirRecurse(dst_path.parentPath.toNativeString());
				auto dstFile = openFile(dst_path, FileMode.CreateTrunc);
				scope(exit) dstFile.close();
				dstFile.put(archive.expand(a));
				journal.add(Journal.Entry(Journal.Type.RegularFile, cleanedPath));
				++countFiles;
			}
		}
		logDiagnostic("%s file(s) copied.", to!string(countFiles));

		// overwrite package.json (this one includes a version field)
		Json pi = jsonFromFile(destination~PackageJsonFilename);
		pi["name"] = toLower(pi["name"].get!string());
		pi["version"] = package_info["version"];
		writeJsonFile(destination~PackageJsonFilename, pi);

		// Write journal
		logDebug("Saving installation journal...");
		journal.add(Journal.Entry(Journal.Type.RegularFile, Path(JournalJsonFilename)));
		journal.save(destination ~ JournalJsonFilename);

		if( existsFile(destination~PackageJsonFilename) )
			logInfo("%s has been installed with version %s", package_name, package_version);

		auto pack = new Package(destination);

		m_packages[package_name] ~= pack;

		return pack;
	}

	void uninstall(in Package pack)
	{
		logDebug("Uninstall %s, version %s, path '%s'", pack.name, pack.vers, pack.path);
		enforce(!pack.path.empty, "Cannot uninstall package "~pack.name~" without a path.");

		// remove package from repositories' list
		bool found = false;
		bool removeFrom(Package[] packs, in Package pack) {
			auto packPos = countUntil!("a.path == b.path")(packs, pack);
			if(packPos != -1) {
				packs = std.algorithm.remove(packs, packPos);
				return true;
			}
			return false;
		}
		foreach(repo; m_repositories) {
			if(removeFrom(repo.localPackages, pack)) {
				found = true;
				break;
			}
		}
		if(!found) {
			foreach(packsOfId; m_packages) {
				if(removeFrom(packsOfId, pack)) {
					found = true;
					break;
				}
			}
		}
		enforce(found, "Cannot uninstall, package not found: '"~ pack.name ~"', path: " ~ to!string(pack.path));

		// delete package files physically
		logDebug("Looking up journal");
		auto journalFile = pack.path~JournalJsonFilename;
		if( !existsFile(journalFile) )
			throw new Exception("Uninstall failed, no installation journal found for '"~pack.name~"'. Please uninstall manually.");

		auto packagePath = pack.path;
		auto journal = new Journal(journalFile);
		logDebug("Erasing files");
		foreach( Journal.Entry e; filter!((Journal.Entry a) => a.type == Journal.Type.RegularFile)(journal.entries)) {
			logDebug("Deleting file '%s'", e.relFilename);
			auto absFile = pack.path~e.relFilename;
			if(!existsFile(absFile)) {
				logWarn("Previously installed file not found for uninstalling: '%s'", absFile);
				continue;
			}

			removeFile(absFile);
		}

		logDiagnostic("Erasing directories");
		Path[] allPaths;
		foreach(Journal.Entry e; filter!((Journal.Entry a) => a.type == Journal.Type.Directory)(journal.entries))
			allPaths ~= pack.path~e.relFilename;
		sort!("a.length>b.length")(allPaths); // sort to erase deepest paths first
		foreach(Path p; allPaths) {
			logDebug("Deleting folder '%s'", p);
			if( !existsFile(p) || !isDir(p.toNativeString()) || !isEmptyDir(p) ) {
				logError("Alien files found, directory is not empty or is not a directory: '%s'", p);
				continue;
			}
			rmdir(p.toNativeString());
		}

		// Erase .dub folder, this is completely erased.
		auto dubDir = (pack.path ~ ".dub/").toNativeString();
		enforce(!existsFile(dubDir) || isDir(dubDir), ".dub should be a directory, but is a file.");
		if(existsFile(dubDir) && isDir(dubDir)) {
			logDebug(".dub directory found, removing directory including content.");
			rmdirRecurse(dubDir);
		}

		logDebug("About to delete root folder for package '%s'.", pack.path);
		if(!isEmptyDir(pack.path))
			throw new Exception("Alien files found in '"~pack.path.toNativeString()~"', needs to be deleted manually.");

		rmdir(pack.path.toNativeString());
		logInfo("Uninstalled package: '"~pack.name~"'");
	}

	Package addLocalPackage(in Path path, in Version ver, LocalPackageType type)
	{
		Package[]* packs = &m_repositories[type].localPackages;
		auto info = jsonFromFile(path ~ PackageJsonFilename, false);
		string name;
		if( "name" !in info ) info["name"] = path.head.toString();
		info["version"] = ver.toString();

		// don't double-add packages
		foreach( p; *packs ){
			if( p.path == path ){
				enforce(p.ver == ver, "Adding local twice with different versions is not allowed.");
				return p;
			}
		}

		auto pack = new Package(info, path);

		*packs ~= pack;

		writeLocalPackageList(type);

		return pack;
	}

	void removeLocalPackage(in Path path, LocalPackageType type)
	{
		Package[]* packs = &m_repositories[type].localPackages;
		size_t[] to_remove;
		foreach( i, entry; *packs )
			if( entry.path == path )
				to_remove ~= i;
		enforce(to_remove.length > 0, "No "~type.to!string()~" package found at "~path.toNativeString());

		foreach_reverse( i; to_remove )
			*packs = (*packs)[0 .. i] ~ (*packs)[i+1 .. $];

		writeLocalPackageList(type);
	}

	Package getTemporaryPackage(Path path, Version ver)
	{
		foreach (p; m_temporaryPackages)
			if (p.path == path) {
				enforce(p.ver == ver, format("Package in %s is refrenced with two conflicting versions: %s vs %s", path.toNativeString(), p.ver, ver));
				return p;
			}
		
		auto info = jsonFromFile(path ~ PackageJsonFilename, false);
		string name;
		if( "name" !in info ) info["name"] = path.head.toString();
		info["version"] = ver.toString();

		auto pack = new Package(info, path);
		m_temporaryPackages ~= pack;
		return pack;
	}

	void addSearchPath(Path path, LocalPackageType type)
	{
		m_repositories[type].searchPath ~= path;
		writeLocalPackageList(type);
	}

	void removeSearchPath(Path path, LocalPackageType type)
	{
		m_repositories[type].searchPath = m_repositories[type].searchPath.filter!(p => p != path)().array();
		writeLocalPackageList(type);
	}

	void refresh(bool refresh_existing_packages)
	{
		// load locally defined packages
		void scanLocalPackages(LocalPackageType type)
		{
			Path list_path = m_repositories[type].packagePath;
			Package[] packs;
			Path[] paths;
			try {
				logDiagnostic("Looking for local package map at %s", list_path.toNativeString());
				if( !existsFile(list_path ~ LocalPackagesFilename) ) return;
				logDiagnostic("Try to load local package map at %s", list_path.toNativeString());
				auto packlist = jsonFromFile(list_path ~ LocalPackagesFilename);
				enforce(packlist.type == Json.Type.Array, LocalPackagesFilename~" must contain an array.");
				foreach( pentry; packlist ){
					try {
						auto name = pentry.name.get!string();
						auto path = Path(pentry.path.get!string());
						if (name == "*") {
							paths ~= path;
						} else {
							auto ver = pentry["version"].get!string();
							auto info = Json.EmptyObject;
							if( existsFile(path ~ PackageJsonFilename) ) info = jsonFromFile(path ~ PackageJsonFilename);
							if( "name" in info && info.name.get!string() != name )
								logWarn("Local package at %s has different name than %s (%s)", path.toNativeString(), name, info.name.get!string());
							info.name = name;
							info["version"] = ver;

							Package pp;
							if (!refresh_existing_packages)
								foreach (p; m_repositories[type].localPackages)
									if (p.path == path) {
										pp = p;
										break;
									}
							if (!pp) pp = new Package(info, path);
							packs ~= pp;
						}
					} catch( Exception e ){
						logWarn("Error adding local package: %s", e.msg);
					}
				}
			} catch( Exception e ){
				logDiagnostic("Loading of local package list at %s failed: %s", list_path.toNativeString(), e.msg);
			}
			m_repositories[type].localPackages = packs;
			m_repositories[type].searchPath = paths;
		}
		scanLocalPackages(LocalPackageType.system);
		scanLocalPackages(LocalPackageType.user);

		Package[][string] old_packages = m_packages;

		// rescan the system and user package folder
		void scanPackageFolder(Path path)
		{
			if( path.existsDirectory() ){
				logDebug("iterating dir %s", path.toNativeString());
				try foreach( pdir; iterateDirectory(path) ){
					logDebug("iterating dir %s entry %s", path.toNativeString(), pdir.name);
					if( !pdir.isDirectory ) continue;
					auto pack_path = path ~ pdir.name;
					if( !existsFile(pack_path ~ PackageJsonFilename) ) continue;
					Package p;
					try {
						if (!refresh_existing_packages)
							foreach (plist; old_packages)
								foreach (pp; plist)
									if (pp.path == pack_path) {
										p = pp;
										break;
									}
						if (!p) p = new Package(pack_path);
						m_packages[p.name] ~= p;
					} catch( Exception e ){
						logError("Failed to load package in %s: %s", pack_path, e.msg);
						logDiagnostic("Full error: %s", e.toString().sanitize());
					}
				}
				catch(Exception e) logDiagnostic("Failed to enumerate %s packages: %s", path.toNativeString(), e.toString());
			}
		}

		m_packages = null;
		foreach (p; this.completeSearchPath)
			scanPackageFolder(p);
	}

	alias ubyte[] Hash;
	/// Generates a hash value for a given package.
	/// Some files or folders are ignored during the generation (like .dub and
	/// .svn folders)
	Hash hashPackage(Package pack) 
	{
		string[] ignored_directories = [".git", ".dub", ".svn"];
		// something from .dub_ignore or what?
		string[] ignored_files = [];
		SHA1 sha1;
		foreach(file; dirEntries(pack.path.toNativeString(), SpanMode.depth)) {
			if(file.isDir && ignored_directories.canFind(Path(file.name).head.toString()))
				continue;
			else if(ignored_files.canFind(Path(file.name).head.toString()))
				continue;

			sha1.put(cast(ubyte[])Path(file.name).head.toString());
			if(file.isDir) {
				logDebug("Hashed directory name %s", Path(file.name).head);
			}
			else {
				sha1.put(openFile(Path(file.name)).readAll());
				logDebug("Hashed file contents from %s", Path(file.name).head);
			}
		}
		auto hash = sha1.finish();
		logDebug("Project hash: %s", hash);
		return hash[0..$];
	}

	private void writeLocalPackageList(LocalPackageType type)
	{
		Json[] newlist;
		foreach (p; m_repositories[type].searchPath) {
			auto entry = Json.EmptyObject;
			entry.name = "*";
			entry.path = p.toNativeString();
			newlist ~= entry;
		}

		foreach (p; m_repositories[type].localPackages) {
			auto entry = Json.EmptyObject;
			entry["name"] = p.name;
			entry["version"] = p.ver.toString();
			entry["path"] = p.path.toNativeString();
			newlist ~= entry;
		}

		Path path = m_repositories[type].packagePath;
		if( !existsDirectory(path) ) mkdirRecurse(path.toNativeString());
		writeJsonFile(path ~ LocalPackagesFilename, Json(newlist));
	}
}
