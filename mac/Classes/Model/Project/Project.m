
#import "ToolOutputWindowController.h"
#import "ATGlobals.h"

#import "PluginManager.h"

#import "Project.h"
#import "OldFSMonitor.h"
#import "OldFSTreeFilter.h"
#import "OldFSTree.h"
#import "Preferences.h"
#import "PluginManager.h"
#import "Compiler.h"
#import "CompilationOptions.h"
#import "LRFile.h"
#import "LRFile2.h"
#import "ImportGraph.h"
#import "ToolOutput.h"
#import "UserScript.h"
#import "FilterOption.h"
#import "Glue.h"
#import "LRPackageResolutionContext.h"
#import "ATPathSpec.h"

#import "Stats.h"
#import "RegexKitLite.h"
#import "NSArray+ATSubstitutions.h"
#import "NSTask+OneLineTasksWithOutput.h"
#import "ATFunctionalStyle.h"
#import "ATAsync.h"
#import "ATObservation.h"
#import "LRCommandLine.h"

#include <stdbool.h>
#include "common.h"
#include "sglib.h"
#include "console.h"
#include "stringutil.h"
#include "eventbus.h"


#define PathKey @"path"

#define DefaultPostProcessingGracePeriod 0.5

NSString *ProjectDidDetectChangeNotification = @"ProjectDidDetectChangeNotification";
NSString *ProjectWillBeginCompilationNotification = @"ProjectWillBeginCompilationNotification";
NSString *ProjectDidEndCompilationNotification = @"ProjectDidEndCompilationNotification";
NSString *ProjectMonitoringStateDidChangeNotification = @"ProjectMonitoringStateDidChangeNotification";
NSString *ProjectNeedsSavingNotification = @"ProjectNeedsSavingNotification";
NSString *ProjectAnalysisDidFinishNotification = @"ProjectAnalysisDidFinishNotification";
NSString *ProjectBuildFinishedNotification = @"ProjectBuildFinishedNotification";

static NSString *CompilersEnabledMonitoringKey = @"someCompilersEnabled";



BOOL MatchLastPathComponent(NSString *path, NSString *lastComponent) {
    return [[path lastPathComponent] isEqualToString:lastComponent];
}

BOOL MatchLastPathTwoComponents(NSString *path, NSString *secondToLastComponent, NSString *lastComponent) {
    NSArray *components = [path pathComponents];
    return components.count >= 2 && [[components objectAtIndex:components.count - 2] isEqualToString:secondToLastComponent] && [[path lastPathComponent] isEqualToString:lastComponent];
}



@interface Project () <FSMonitorDelegate>

- (void)updateFilter;
- (void)handleCompilationOptionsEnablementChanged;

- (void)updateImportGraphForPaths:(NSSet *)paths;
- (void)rebuildImportGraph;

- (void)processPendingChanges;

@end


@implementation Project

@synthesize path=_path;
@synthesize dirty=_dirty;
@synthesize lastSelectedPane=_lastSelectedPane;
@synthesize enabled=_enabled;
@synthesize compilationEnabled=_compilationEnabled;
@synthesize postProcessingCommand=_postProcessingCommand;
@synthesize postProcessingScriptName=_postProcessingScriptName;
@synthesize postProcessingEnabled=_postProcessingEnabled;
@synthesize disableLiveRefresh=_disableLiveRefresh;
@synthesize enableRemoteServerWorkflow=_enableRemoteServerWorkflow;
@synthesize fullPageReloadDelay=_fullPageReloadDelay;
@synthesize eventProcessingDelay=_eventProcessingDelay;
@synthesize postProcessingGracePeriod=_postProcessingGracePeriod;
@synthesize rubyVersionIdentifier=_rubyVersionIdentifier;
@synthesize numberOfPathComponentsToUseAsName=_numberOfPathComponentsToUseAsName;
@synthesize customName=_customName;
@synthesize urlMasks=_urlMasks;


#pragma mark -
#pragma mark Init/dealloc

- (id)initWithURL:(NSURL *)rootURL memento:(NSDictionary *)memento {
    if ((self = [super init])) {
        _rootURL = rootURL;
        [self _updateValuesDerivedFromRootURL];

        _enabled = YES;

        _fileDatesHack = [NSMutableDictionary new];

        _compilerOptions = [[NSMutableDictionary alloc] init];
        _monitoringRequests = [[NSMutableSet alloc] init];
        _runningAnalysisTasks = [NSMutableSet new];

        _resolutionContext = [[LRPackageResolutionContext alloc] init];

        _actionList = [[ActionList alloc] initWithActionTypes:[PluginManager sharedPluginManager].actionTypes project:self];
        [_actionList setMemento:memento];

        _lastSelectedPane = [[memento objectForKey:@"last_pane"] copy];

        id raw = [memento objectForKey:@"compilers"];
        if (raw) {
            PluginManager *pluginManager = [PluginManager sharedPluginManager];
            [raw enumerateKeysAndObjectsUsingBlock:^(id uniqueId, id compilerMemento, BOOL *stop) {
                Compiler *compiler = [pluginManager compilerWithUniqueId:uniqueId];
                if (compiler) {
                    [_compilerOptions setObject:[[CompilationOptions alloc] initWithCompiler:compiler memento:compilerMemento] forKey:uniqueId];
                } else {
                    // TODO: save data for unknown compilers and re-add them when creating a memento
                }
            }];
        }

        if ([memento objectForKey:@"compilationEnabled"]) {
            _compilationEnabled = [[memento objectForKey:@"compilationEnabled"] boolValue];
        } else {
            _compilationEnabled = NO;
            [[memento objectForKey:@"compilers"] enumerateKeysAndObjectsUsingBlock:^(id uniqueId, id compilerMemento, BOOL *stop) {
                if ([[compilerMemento objectForKey:@"mode"] isEqualToString:@"compile"]) {
                    _compilationEnabled = YES;
                }
            }];
        }

        _disableLiveRefresh = [[memento objectForKey:@"disableLiveRefresh"] boolValue];
        _enableRemoteServerWorkflow = [[memento objectForKey:@"enableRemoteServerWorkflow"] boolValue];

        if ([memento objectForKey:@"fullPageReloadDelay"])
            _fullPageReloadDelay = [[memento objectForKey:@"fullPageReloadDelay"] doubleValue];
        else
            _fullPageReloadDelay = 0.0;

        if ([memento objectForKey:@"eventProcessingDelay"])
            _eventProcessingDelay = [[memento objectForKey:@"eventProcessingDelay"] doubleValue];
        else
            _eventProcessingDelay = 0.0;

        _postProcessingCommand = [[memento objectForKey:@"postproc"] copy];
        _postProcessingScriptName = [[memento objectForKey:@"postprocScript"] copy];
        if ([memento objectForKey:@"postprocEnabled"]) {
            _postProcessingEnabled = [[memento objectForKey:@"postprocEnabled"] boolValue];
        } else {
            _postProcessingEnabled = [_postProcessingScriptName length] > 0 || [_postProcessingCommand length] > 0;
        }

        _rubyVersionIdentifier = [[memento objectForKey:@"rubyVersion"] copy];
        if ([_rubyVersionIdentifier length] == 0)
            _rubyVersionIdentifier = @"system";

        _importGraph = [[ImportGraph alloc] init];

        NSArray *excludedPaths = [memento objectForKey:@"excludedPaths"];
        if (excludedPaths == nil)
            excludedPaths = [NSArray array];
        _excludedFolderPaths = [[NSMutableArray alloc] initWithArray:excludedPaths];

        NSArray *urlMasks = [memento objectForKey:@"urls"];
        if (urlMasks == nil)
            urlMasks = [NSArray array];
        _urlMasks = [urlMasks copy];

        _numberOfPathComponentsToUseAsName = [[memento objectForKey:@"numberOfPathComponentsToUseAsName"] integerValue];
        if (_numberOfPathComponentsToUseAsName == 0)
            _numberOfPathComponentsToUseAsName = 1;

        _customName = [memento objectForKey:@"customName"] ?: @"";

        _pendingChanges = [[NSMutableSet alloc] init];

        if ([memento objectForKey:@"postProcessingGracePeriod"])
            _postProcessingGracePeriod = [[memento objectForKey:@"postProcessingGracePeriod"] doubleValue];
        else
            _postProcessingGracePeriod = DefaultPostProcessingGracePeriod;

        if ([[memento objectForKey:@"advanced"] isKindOfClass:NSArray.class])
            _superAdvancedOptions = [memento objectForKey:@"advanced"];
        else
            _superAdvancedOptions = @[];
        [self _parseSuperAdvancedOptions];

        [self _updateAccessibility:YES];
        [self handleCompilationOptionsEnablementChanged];
        [self requestMonitoring:YES forKey:@"ui"];  // always need a folder list for UI
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)setRootURL:(NSURL *)rootURL {
    if (![_rootURL isEqual:rootURL]) {
        _rootURL = rootURL;
        [self _updateValuesDerivedFromRootURL];
        [self _updateAccessibility:NO];
    }
}

- (void)_updateValuesDerivedFromRootURL {
    // we cannot monitor through symlink boundaries anyway
    [self willChangeValueForKey:@"path"];
    _path = [[_rootURL path] stringByResolvingSymlinksInPath];
    [self didChangeValueForKey:@"path"];
}

- (void)updateAccessibility {
    [self _updateAccessibility:NO];
}

- (void)_updateAccessibility:(BOOL)initially {
    BOOL wasAccessible = _accessible;

    [self willChangeValueForKey:@"accessible"];
    [self willChangeValueForKey:@"exists"];
    ATPathAccessibility acc = ATCheckPathAccessibility(_rootURL);
    if (acc == ATPathAccessibilityAccessible) {
        _accessible = YES;
        _exists = YES;
    } else if (acc == ATPathAccessibilityNotFound) {
        _accessible = NO;
        _exists = NO;
    } else if ([_rootURL startAccessingSecurityScopedResource]) {
        _accessible = YES;
        _accessingSecurityScopedResource = YES;
        _exists = YES;
    } else {
        _accessible = NO;
        _exists = YES;
    }
    [self didChangeValueForKey:@"accessible"];
    [self didChangeValueForKey:@"exists"];

    if (!initially && (!wasAccessible && _accessible)) {
        // save to create a bookmark
        [[NSNotificationCenter defaultCenter] postNotificationName:@"SomethingChanged" object:self];
    }

    if (_accessible && !_monitor) {
        _monitor = [[FSMonitor alloc] initWithPath:_path];
        _monitor.delegate = self;
        _monitor.eventProcessingDelay = _eventProcessingDelay;
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(updateFilter) name:PreferencesFilterSettingsChangedNotification object:nil];
        [self updateFilter];
        [self _updateMonitoringState];
    }
}


#pragma mark -
#pragma mark Persistence

- (NSMutableDictionary *)memento {
    NSMutableDictionary *memento = [NSMutableDictionary dictionary];
    [memento setObject:[_compilerOptions dictionaryByMappingValuesToSelector:@selector(memento)] forKey:@"compilers"];
    if (_lastSelectedPane)
        [memento setObject:_lastSelectedPane forKey:@"last_pane"];
    if ([_postProcessingCommand length] > 0) {
        [memento setObject:_postProcessingCommand forKey:@"postproc"];
    }
    if ([_postProcessingScriptName length] > 0) {
        [memento setObject:_postProcessingScriptName forKey:@"postprocScript"];
        [memento setObject:[NSNumber numberWithBool:_postProcessingEnabled] forKey:@"postprocEnabled"];
    }
    [memento setObject:[NSNumber numberWithBool:_disableLiveRefresh] forKey:@"disableLiveRefresh"];
    [memento setObject:[NSNumber numberWithBool:_enableRemoteServerWorkflow] forKey:@"enableRemoteServerWorkflow"];
    if (_fullPageReloadDelay > 0.001) {
        [memento setObject:[NSNumber numberWithDouble:_fullPageReloadDelay] forKey:@"fullPageReloadDelay"];
    }
    if (_eventProcessingDelay > 0.001) {
        [memento setObject:[NSNumber numberWithDouble:_eventProcessingDelay] forKey:@"eventProcessingDelay"];
    }
    if (fabs(_postProcessingGracePeriod - DefaultPostProcessingGracePeriod) > 0.01) {
        [memento setObject:[NSNumber numberWithDouble:_postProcessingGracePeriod] forKey:@"postProcessingGracePeriod"];
    }
    if ([_excludedFolderPaths count] > 0) {
        [memento setObject:_excludedFolderPaths forKey:@"excludedPaths"];
    }
    if ([_urlMasks count] > 0) {
        [memento setObject:_urlMasks forKey:@"urls"];
    }
    [memento setObject:_rubyVersionIdentifier forKey:@"rubyVersion"];
    [memento setObject:[NSNumber numberWithBool:_compilationEnabled ] forKey:@"compilationEnabled"];

    [memento setObject:[NSNumber numberWithInteger:_numberOfPathComponentsToUseAsName] forKey:@"numberOfPathComponentsToUseAsName"];
    if (_customName.length > 0)
        [memento setObject:_customName forKey:@"customName"];

    if (_superAdvancedOptions.count > 0)
        [memento setObject:_superAdvancedOptions forKey:@"advanced"];

    [memento setValuesForKeysWithDictionary:_actionList.memento];

    return memento;
}


#pragma mark - Displaying

- (NSString *)displayName {
    if (_numberOfPathComponentsToUseAsName == ProjectUseCustomName)
        return _customName;
    else {
        // if there aren't as many components any more (well who knows, right?), display one
        NSString *name = [self proposedNameAtIndex:_numberOfPathComponentsToUseAsName - 1];
        if (name)
            return name;
        else
            return [self proposedNameAtIndex:0];
    }
}

- (NSString *)displayPath {
    return [_path stringByAbbreviatingWithTildeInPath];
}

- (NSString *)description {
    return [NSString stringWithFormat:@"Project(%@)", [self displayPath]];
}

- (NSComparisonResult)compareByDisplayPath:(Project *)another {
    return [self.displayPath compare:another.displayPath];
}

- (NSString *)proposedNameAtIndex:(NSInteger)index {
    NSArray *components = [self.displayPath pathComponents];
    NSInteger count = [components count];
    index = count - 1 - index;
    if (index < 0)
        return nil;
    if (index == 0 && [[components objectAtIndex:0] isEqualToString:@"~"])
        return nil;
    return [[components subarrayWithRange:NSMakeRange(index, count - index)] componentsJoinedByString:@"/"];
}


#pragma mark - Filtering

- (void)updateFilter {
    // Cannot ignore hidden files, some guys are using files like .navigation.html as
    // partials. Not sure about directories, but the usual offenders are already on
    // the excludedNames list.
    FSTreeFilter *filter = _monitor.filter;
    NSSet *excludedPaths = [NSSet setWithArray:_excludedFolderPaths];
    if (filter.ignoreHiddenFiles != NO || ![filter.enabledExtensions isEqualToSet:[Preferences sharedPreferences].allExtensions] || ![filter.excludedNames isEqualToSet:[Preferences sharedPreferences].excludedNames] || ![filter.excludedPaths isEqualToSet:excludedPaths]) {
        filter.ignoreHiddenFiles = NO;
        filter.enabledExtensions = [Preferences sharedPreferences].allExtensions;
        filter.excludedNames = [Preferences sharedPreferences].excludedNames;
        filter.excludedPaths = excludedPaths;
        [_monitor filterUpdated];
    }
}


#pragma mark -
#pragma mark File System Monitoring

- (void)ceaseAllMonitoring {
    [_monitoringRequests removeAllObjects];
    _monitor.running = NO;
}

- (void)checkBrokenPaths {
    if (_brokenPathReported)
        return;
    if (![[NSFileManager defaultManager] fileExistsAtPath:_path])
        return; // don't report spurious messages for missing folders

    NSArray *brokenPaths = [[_monitor obtainTree] brokenPaths];
    if ([brokenPaths count] > 0) {
        NSInteger result = [[NSAlert alertWithMessageText:@"Folder Cannot Be Monitored" defaultButton:@"Read More" alternateButton:@"Ignore" otherButton:nil informativeTextWithFormat:@"The following %@ cannot be monitored because of OS X FSEvents bug:\n\n\t%@\n\nMore info and workaround instructions are available on our site.", [brokenPaths count] > 0 ? @"folders" : @"folder", [[brokenPaths componentsJoinedByString:@"\n\t"] stringByReplacingOccurrencesOfString:@"_!LR_BROKEN!_" withString:@"Broken"]] runModal];
        if (result == NSAlertDefaultReturn) {
            [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"http://help.livereload.com/kb/troubleshooting/os-x-fsevents-bug-may-prevent-monitoring-of-certain-folders"]];
        }
        _brokenPathReported = YES;
    }
}

- (BOOL)isFileImported:(NSString *)path {
    return [_importGraph hasReferencingPathsForPath:path];
}


- (void)requestMonitoring:(BOOL)monitoringEnabled forKey:(NSString *)key {
    if ([_monitoringRequests containsObject:key] != monitoringEnabled) {
        if (monitoringEnabled) {
//            NSLog(@"%@: requesting monitoring for %@", [self description], key);
            [_monitoringRequests addObject:key];
        } else {
//            NSLog(@"%@: unrequesting monitoring for %@", [self description], key);
            [_monitoringRequests removeObject:key];
        }

        [self _updateMonitoringState];
    }
}

- (void)_updateMonitoringState {
    BOOL shouldBeRunning = [_monitoringRequests count] > 0;
    if (_monitor && (shouldBeRunning != _monitor.running)) {
        if (shouldBeRunning) {
            NSLog(@"Activated monitoring for %@", [self displayPath]);
        } else {
            NSLog(@"Deactivated monitoring for %@", [self displayPath]);
        }
        _monitor.running = shouldBeRunning;
        if (shouldBeRunning) {
            [self rebuildImportGraph];
            [self checkBrokenPaths];
        }
        [[NSNotificationCenter defaultCenter] postNotificationName:ProjectMonitoringStateDidChangeNotification object:self];
    }
}

- (void)compile:(NSString *)relativePath under:(NSString *)rootPath with:(Compiler *)compiler options:(CompilationOptions *)compilationOptions {
    NSString *path = [rootPath stringByAppendingPathComponent:relativePath];

    if (![[NSFileManager defaultManager] fileExistsAtPath:path])
        return; // don't try to compile deleted files
    LRFile *fileOptions = [self optionsForFileAtPath:relativePath in:compilationOptions];
    if (fileOptions.destinationDirectory != nil || !compiler.needsOutputDirectory) {
        NSString *derivedName = fileOptions.destinationName;
        NSString *derivedPath = (compiler.needsOutputDirectory ? [fileOptions.destinationDirectory stringByAppendingPathComponent:derivedName] : [[path stringByDeletingLastPathComponent] stringByAppendingPathComponent:derivedName]);

        ToolOutput *compilerOutput = nil;
        [compiler compile:relativePath into:derivedPath under:rootPath inProject:self with:compilationOptions compilerOutput:&compilerOutput];
        if (compilerOutput) {
            compilerOutput.project = self;

            [[[ToolOutputWindowController alloc] initWithCompilerOutput:compilerOutput key:path] show];
        } else {
            [ToolOutputWindowController hideOutputWindowWithKey:path];
        }
    } else {
        NSLog(@"Ignoring %@ because destination directory is not set.", relativePath);
    }
}

- (BOOL)isCompassConfigurationFile:(NSString *)relativePath {
    return MatchLastPathTwoComponents(relativePath, @"config", @"compass.rb") || MatchLastPathTwoComponents(relativePath, @".compass", @"config.rb") || MatchLastPathTwoComponents(relativePath, @"config", @"compass.config") || MatchLastPathComponent(relativePath, @"config.rb") || MatchLastPathTwoComponents(relativePath, @"src", @"config.rb");
}

- (void)scanCompassConfigurationFile:(NSString *)relativePath {
    NSString *data = [NSString stringWithContentsOfFile:[self.path stringByAppendingPathComponent:relativePath] encoding:NSUTF8StringEncoding error:nil];
    if (data) {
        if ([data isMatchedByRegex:@"compass plugins"] || [data isMatchedByRegex:@"^preferred_syntax = :(sass|scss)" options:RKLMultiline inRange:NSMakeRange(0, data.length) error:nil]) {
            _compassDetected = YES;
        }
    }
}

- (void)processChangeAtPath:(NSString *)relativePath reloadRequests:(NSMutableArray *)reloadRequests {
    NSString *extension = [relativePath pathExtension];

    BOOL compilerFound = NO;
    for (Compiler *compiler in [PluginManager sharedPluginManager].compilers) {
        if (_compassDetected && [compiler.uniqueId isEqualToString:@"sass"])
            continue;
        else if (!_compassDetected && [compiler.uniqueId isEqualToString:@"compass"])
            continue;
        if ([compiler.extensions containsObject:extension]) {
            compilerFound = YES;
            CompilationOptions *compilationOptions = [self optionsForCompiler:compiler create:YES];
            if (_compilationEnabled && compilationOptions.active) {
                [[NSNotificationCenter defaultCenter] postNotificationName:ProjectWillBeginCompilationNotification object:self];
                [self compile:relativePath under:_path with:compiler options:compilationOptions];
                [[NSNotificationCenter defaultCenter] postNotificationName:ProjectDidEndCompilationNotification object:self];
                StatGroupIncrement(CompilerChangeCountStatGroup, compiler.uniqueId, 1);
                StatGroupIncrement(CompilerChangeCountEnabledStatGroup, compiler.uniqueId, 1);
                break;
            } else {
                LRFile *fileOptions = [self optionsForFileAtPath:relativePath in:compilationOptions];
                NSString *derivedName = fileOptions.destinationName;
                NSString *originalPath = [_path stringByAppendingPathComponent:relativePath];
                [reloadRequests addObject:@{@"path": derivedName, @"originalPath": originalPath}];
                NSLog(@"Broadcasting a fake change in %@ instead of %@ (compiler %@).", derivedName, relativePath, compiler.name);
                StatGroupIncrement(CompilerChangeCountStatGroup, compiler.uniqueId, 1);
                break;
//            } else if (compilationOptions.mode == CompilationModeDisabled) {
//                compilerFound = NO;
            }
        }
    }

    if (!compilerFound) {
        if (_forcedStylesheetReloadSpec && [_forcedStylesheetReloadSpec matchesPath:relativePath type:ATPathSpecEntryTypeFile]) {
            [reloadRequests addObject:@{@"path": @"force-reload-all-stylesheets.css", @"originalPath": [NSNull null]}];
        } else {
            [reloadRequests addObject:@{@"path": [_path stringByAppendingPathComponent:relativePath], @"originalPath": [NSNull null]}];
        }
    }
}

// I don't think this will ever be needed, but not throwing the code away yet
#ifdef AUTORESCAN_WORKAROUND_ENABLED
- (void)rescanRecentlyChangedPaths {
    NSLog(@"Rescanning %@ again in case some compiler was slow to write the changes.", _path);
    [_monitor rescan];
}
#endif

- (void)fileSystemMonitor:(FSMonitor *)monitor detectedChange:(FSChange *)change {
    [_pendingChanges unionSet:change.changedFiles];

    if (!(_runningPostProcessor || (_lastPostProcessingRunDate > 0 && [NSDate timeIntervalSinceReferenceDate] < _lastPostProcessingRunDate + _postProcessingGracePeriod))) {
        _pendingPostProcessing = YES;
    }

    [self processPendingChanges];

    if (change.folderListChanged) {
        [self willChangeValueForKey:@"filterOptions"];
        [self didChangeValueForKey:@"filterOptions"];
    }
}

- (void)processBatchOfPendingChanges:(NSSet *)pathes {
    BOOL invokePostProcessor = _pendingPostProcessing;
    _pendingPostProcessing = NO;

    ++_buildsRunning;

    switch (pathes.count) {
        case 0:  break;
        case 1:  console_printf("Changed: %s", [[pathes anyObject] UTF8String]); break;
        default: console_printf("Changed: %s and %d others", [[pathes anyObject] UTF8String], (int)pathes.count - 1); break;
    }

    [self updateImportGraphForPaths:pathes];

    NSMutableArray *reloadRequests = [NSMutableArray new];

#ifdef AUTORESCAN_WORKAROUND_ENABLED
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(rescanRecentlyChangedPaths) object:nil];
    [self performSelector:@selector(rescanRecentlyChangedPaths) withObject:nil afterDelay:1.0];
#endif

    for (NSString *relativePath in pathes) {
        NSSet *realPaths = [_importGraph rootReferencingPathsForPath:relativePath];
        if ([realPaths count] > 0) {
            NSLog(@"Instead of imported file %@, processing changes in %@", relativePath, [[realPaths allObjects] componentsJoinedByString:@", "]);
            for (NSString *path in realPaths) {
                [self processChangeAtPath:path reloadRequests:reloadRequests];
            }
        } else {
            [self processChangeAtPath:relativePath reloadRequests:reloadRequests];
        }
    }

    NSArray *actions = [self.actionList.activeActions copy];
    NSArray *pathArray = [pathes allObjects];
    NSArray *perFileActions = [actions filteredArrayUsingBlock:^BOOL(Action *action) {
        return action.kind == ActionKindFilter || action.kind == ActionKindCompiler;
    }];

    [perFileActions enumerateObjectsAsynchronouslyUsingBlock:^(Action *action, NSUInteger idx, void (^callback1)(BOOL stop)) {
        NSArray *matchingPaths = [action.inputPathSpec matchingPathsInArray:pathArray type:ATPathSpecEntryTypeFile];
        [matchingPaths enumerateObjectsAsynchronouslyUsingBlock:^(NSString *path, NSUInteger idx, void (^callback2)(BOOL stop)) {
            LRFile2 *file = [LRFile2 fileWithRelativePath:path project:self];
            if ([action shouldInvokeForFile:file]) {
                [action compileFile:file inProject:self completionHandler:^(BOOL invoked, ToolOutput *output, NSError *error) {
                    if (error) {
                        NSLog(@"Error compiling %@: %@ - %ld - %@", path, error.domain, (long)error.code, error.localizedDescription);
                    }
                    [self displayCompilationError:output key:[NSString stringWithFormat:@"%@.%@", _path, path]];
                    callback2(NO);
                }];
            } else {
                callback2(NO);
            }
        } completionBlock:^{
            callback1(NO);
        }];
    } completionBlock:^{
        if (reloadRequests.count > 0) {
            if (_postProcessingScriptName.length > 0 && _postProcessingEnabled) {
                if (invokePostProcessor && actions.count > 0) {
                    _runningPostProcessor = YES;
                    [self invokeNextActionInArray:actions withModifiedPaths:pathes];
                } else {
                    console_printf("Skipping post-processing.");
                }

#if 0
                UserScript *userScript = self.postProcessingScript;
                if (invokePostProcessor && userScript.exists) {
                    ToolOutput *toolOutput = nil;

                    _runningPostProcessor = YES;
                    [userScript invokeForProjectAtPath:_path withModifiedFiles:pathes completionHandler:^(BOOL invoked, ToolOutput *output, NSError *error) {
                        _runningPostProcessor = NO;
                        _lastPostProcessingRunDate = [NSDate timeIntervalSinceReferenceDate];

                        if (toolOutput) {
                            toolOutput.project = self;
                            [[[ToolOutputWindowController alloc] initWithCompilerOutput:toolOutput key:[NSString stringWithFormat:@"%@.postproc", _path]] show];
                        }
                    }];
                } else {
                    console_printf("Skipping post-processing.");
                }
#endif
            }

            [[Glue glue] postMessage:@{@"service": @"reloader", @"command": @"reload", @"changes": reloadRequests, @"forceFullReload": @(self.disableLiveRefresh), @"fullReloadDelay": @(_fullPageReloadDelay)}];

            [[NSNotificationCenter defaultCenter] postNotificationName:ProjectDidDetectChangeNotification object:self];
            StatIncrement(BrowserRefreshCountStat, 1);
        }

        --_buildsRunning;
        [self checkIfBuildFinished];

//        S_app_handle_change(json_object_2("root", json_nsstring(_path), "paths", nodeapp_objc_to_json([pathes allObjects])));
    }];
}

- (void)startBuild {
    if (!_buildInProgress) {
        _buildInProgress = YES;
        NSLog(@"Build starting...");
    }
}

- (void)checkIfBuildFinished {
    if (_buildInProgress && !(_buildsRunning > 0 || _processingChanges)) {
        _buildInProgress = NO;
        NSLog(@"Build finished.");
        [self postNotificationName:ProjectBuildFinishedNotification];
    }
}

- (void)displayCompilationError:(ToolOutput *)output key:(NSString *)key {
    if (output) {
        NSLog(@"Compilation error in %@:\n%@", key, output.output);
        output.project = self;
        [[[ToolOutputWindowController alloc] initWithCompilerOutput:output key:key] show];
    } else {
        [ToolOutputWindowController hideOutputWindowWithKey:key];
    }
}

- (void)invokeNextActionInArray:(NSArray *)actions withModifiedPaths:(NSSet *)paths {
    if (actions.count == 0) {
        _runningPostProcessor = NO;
        _lastPostProcessingRunDate = [NSDate timeIntervalSinceReferenceDate];
        return;
    }

    Action *action = [actions firstObject];
    actions = [actions subarrayWithRange:NSMakeRange(1, actions.count - 1)];

    if (action.kind == ActionKindPostproc && [action shouldInvokeForModifiedFiles:paths inProject:self]) {
        [action invokeForProjectAtPath:_path withModifiedFiles:paths completionHandler:^(BOOL invoked, ToolOutput *output, NSError *error) {
            [self displayCompilationError:output key:[NSString stringWithFormat:@"%@.postproc", _path]];

            dispatch_async(dispatch_get_main_queue(), ^{
                [self invokeNextActionInArray:actions withModifiedPaths:paths];
            });
        }];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self invokeNextActionInArray:actions withModifiedPaths:paths];
        });
    }
}

- (void)processPendingChanges {
    if (_processingChanges)
        return;

    [self startBuild];
    _processingChanges = YES;

    while (_pendingChanges.count > 0 || _pendingPostProcessing) {
        NSSet *paths = _pendingChanges;
        _pendingChanges = [[NSMutableSet alloc] init];
        [self processBatchOfPendingChanges:paths];
    }

    _processingChanges = NO;
    [self checkIfBuildFinished];
}

- (FSTree *)tree {
    return _monitor.tree;
}

- (FSTree *)obtainTree {
    return [_monitor obtainTree];
}

- (void)rescanTree {
    [_monitor rescan];
}


#pragma mark - Compilation

- (NSArray *)compilersInUse {
    FSTree *tree = [_monitor obtainTree];
    return [[PluginManager sharedPluginManager].compilers filteredArrayUsingBlock:^BOOL(id value) {
        Compiler *compiler = value;
        if (_compassDetected && [compiler.uniqueId isEqualToString:@"sass"])
            return NO;
        else if (!_compassDetected && [compiler.uniqueId isEqualToString:@"compass"])
            return NO;
        return [compiler pathsOfSourceFilesInTree:tree].count > 0;
    }];
}


#pragma mark - Options

- (void)setCustomName:(NSString *)customName {
    if (_customName != customName) {
        _customName = customName;
        [[NSNotificationCenter defaultCenter] postNotificationName:@"SomethingChanged" object:self];
    }
}

- (void)setNumberOfPathComponentsToUseAsName:(NSInteger)numberOfPathComponentsToUseAsName {
    if (_numberOfPathComponentsToUseAsName != numberOfPathComponentsToUseAsName) {
        _numberOfPathComponentsToUseAsName = numberOfPathComponentsToUseAsName;
        [[NSNotificationCenter defaultCenter] postNotificationName:@"SomethingChanged" object:self];
    }
}

- (CompilationOptions *)optionsForCompiler:(Compiler *)compiler create:(BOOL)create {
    NSString *uniqueId = compiler.uniqueId;
    CompilationOptions *options = [_compilerOptions objectForKey:uniqueId];
    if (options == nil && create) {
        options = [[CompilationOptions alloc] initWithCompiler:compiler memento:nil];
        [_compilerOptions setObject:options forKey:uniqueId];
        [[NSNotificationCenter defaultCenter] postNotificationName:@"SomethingChanged" object:self];
    }
    return options;
}

- (id)enumerateParentFoldersFromFolder:(NSString *)folder with:(id(^)(NSString *folder, NSString *relativePath, BOOL *stop))block {
    BOOL stop = NO;
    NSString *relativePath = @"";
    id result;
    if ((result = block(folder, relativePath, &stop)) != nil)
        return result;
    while (!stop && [[folder pathComponents] count] > 1) {
        relativePath = [[folder lastPathComponent] stringByAppendingPathComponent:relativePath];
        folder = [folder stringByDeletingLastPathComponent];
        if ((result = block(folder, relativePath, &stop)) != nil)
            return result;
    }
    return nil;
}

- (LRFile *)optionsForFileAtPath:(NSString *)sourcePath in:(CompilationOptions *)compilationOptions {
    LRFile *fileOptions = [compilationOptions optionsForFileAtPath:sourcePath create:YES];

    @autoreleasepool {

    FSTree *tree = self.tree;
    if (fileOptions.destinationNameMask.length == 0) {
        // for a name like foo.php.jade, check if foo.php already exists in the project
        NSString *bareName = [[sourcePath lastPathComponent] stringByDeletingPathExtension];
        if ([bareName pathExtension].length > 0 && tree && [tree containsFileNamed:bareName]) {
            fileOptions.destinationName = bareName;
        } else {
            fileOptions.destinationNameMask = [NSString stringWithFormat:@"*.%@", compilationOptions.compiler.destinationExtension];
        }
    }

    if (fileOptions.destinationDirectory == nil) {
        // see if we can guess it
        NSString *guessedDirectory = nil;

        // 1) destination file already exists?
        NSString *derivedName = fileOptions.destinationName;
        NSArray *derivedPaths = [self.tree pathsOfFilesNamed:derivedName];
        if (derivedPaths.count > 0) {
            NSString *defaultDerivedFile = [[sourcePath stringByDeletingLastPathComponent] stringByAppendingPathComponent:fileOptions.destinationName];

            if ([derivedPaths containsObject:defaultDerivedFile]) {
                guessedDirectory = [sourcePath stringByDeletingLastPathComponent];
                NSLog(@"Guessed output directory for %@ by existing output file in the same folder: %@", sourcePath, defaultDerivedFile);
            } else {
                NSArray *unoccupiedPaths = [derivedPaths filteredArrayUsingBlock:^BOOL(id value) {
                    NSString *derivedPath = value;
                    return [compilationOptions sourcePathThatCompilesInto:derivedPath] == nil;
                }];
                if (unoccupiedPaths.count == 1) {
                    guessedDirectory = [[unoccupiedPaths objectAtIndex:0] stringByDeletingLastPathComponent];
                    NSLog(@"Guessed output directory for %@ by existing output file %@", sourcePath, [unoccupiedPaths objectAtIndex:0]);
                }
            }
        }

        // 2) other files in the same folder have a common destination path?
        if (guessedDirectory == nil) {
            NSString *sourceDirectory = [sourcePath stringByDeletingLastPathComponent];
            NSArray *otherFiles = [[compilationOptions.compiler pathsOfSourceFilesInTree:self.tree] filteredArrayUsingBlock:^BOOL(id value) {
                return ![sourcePath isEqualToString:value] && [sourceDirectory isEqualToString:[value stringByDeletingLastPathComponent]];
            }];
            if ([otherFiles count] > 0) {
                NSArray *otherFileOptions = [otherFiles arrayByMappingElementsUsingBlock:^id(id otherFilePath) {
                    return [compilationOptions optionsForFileAtPath:otherFilePath create:NO];
                }];
                NSString *common = [LRFile commonOutputDirectoryFor:otherFileOptions inProject:self];
                if ([common isEqualToString:@"__NONE_SET__"]) {
                    // nothing to figure it from
                } else if (common == nil) {
                    // different directories, something complicated is going on here;
                    // don't try to be too smart and just give up
                    NSLog(@"Refusing to guess output directory for %@ because other files in the same directory have varying output directories", sourcePath);
                    goto skipGuessing;
                } else {
                    guessedDirectory = common;
                    NSLog(@"Guessed output directory for %@ based on configuration of other files in the same directory", sourcePath);
                }
            }
        }

        // 3) are we in a subfolder with one of predefined 'output' names? (e.g. css/something.less)
        if (guessedDirectory == nil) {
            NSSet *magicNames = [NSSet setWithArray:compilationOptions.compiler.expectedOutputDirectoryNames];
            guessedDirectory = [self enumerateParentFoldersFromFolder:[sourcePath stringByDeletingLastPathComponent] with:^(NSString *folder, NSString *relativePath, BOOL *stop) {
                if ([magicNames containsObject:[folder lastPathComponent]]) {
                    NSLog(@"Guessed output directory for %@ to be its own parent folder (%@) based on being located inside a folder with magical name %@", sourcePath, [sourcePath stringByDeletingLastPathComponent], folder);
                    return (id)[sourcePath stringByDeletingLastPathComponent];
                }
                return (id)nil;
            }];
        }

        // 4) is there a sibling directory with one of predefined 'output' names? (e.g. smt/css/ for smt/src/foo/file.styl)
        if (guessedDirectory == nil) {
            NSSet *magicNames = [NSSet setWithArray:compilationOptions.compiler.expectedOutputDirectoryNames];
            guessedDirectory = [self enumerateParentFoldersFromFolder:[sourcePath stringByDeletingLastPathComponent] with:^(NSString *folder, NSString *relativePath, BOOL *stop) {
                NSString *parent = [folder stringByDeletingLastPathComponent];
                NSFileManager *fm = [NSFileManager defaultManager];
                for (NSString *magicName in magicNames) {
                    NSString *possibleDir = [parent stringByAppendingPathComponent:magicName];
                    BOOL isDir = NO;
                    if ([fm fileExistsAtPath:[_path stringByAppendingPathComponent:possibleDir] isDirectory:&isDir])
                        if (isDir) {
                            // TODO: decide whether or not to append relativePath based on existence of other files following the same convention
                            NSString *guess = [possibleDir stringByAppendingPathComponent:relativePath];
                            NSLog(@"Guessed output directory for %@ to be %@ based on a sibling folder with a magical name %@", sourcePath, guess, possibleDir);
                            return (id)guess;
                        }
                }
                return (id)nil;
            }];
        }

        // 5) if still nothing, put the result in the same folder
        if (guessedDirectory == nil) {
            guessedDirectory = [sourcePath stringByDeletingLastPathComponent];
        }

        if (guessedDirectory) {
            fileOptions.destinationDirectory = guessedDirectory;
        }
    }
skipGuessing:
        ;
    }
    return fileOptions;
}

- (void)handleCompilationOptionsEnablementChanged {
    [self requestMonitoring:_compilationEnabled || _postProcessingEnabled forKey:CompilersEnabledMonitoringKey];
}

- (void)setCompilationEnabled:(BOOL)compilationEnabled {
    if (_compilationEnabled != compilationEnabled) {
        _compilationEnabled = compilationEnabled;
        [self handleCompilationOptionsEnablementChanged];
        [[NSNotificationCenter defaultCenter] postNotificationName:@"SomethingChanged" object:self];
    }
}

- (void)setDisableLiveRefresh:(BOOL)disableLiveRefresh {
    if (_disableLiveRefresh != disableLiveRefresh) {
        _disableLiveRefresh = disableLiveRefresh;
        [[NSNotificationCenter defaultCenter] postNotificationName:@"SomethingChanged" object:self];
    }
}

- (void)setEnableRemoteServerWorkflow:(BOOL)enableRemoteServerWorkflow {
    if (_enableRemoteServerWorkflow != enableRemoteServerWorkflow) {
        _enableRemoteServerWorkflow = enableRemoteServerWorkflow;
        [[NSNotificationCenter defaultCenter] postNotificationName:@"SomethingChanged" object:self];
    }
}

- (void)setFullPageReloadDelay:(NSTimeInterval)fullPageReloadDelay {
    if (fneq(_fullPageReloadDelay, fullPageReloadDelay, TIME_EPS)) {
        _fullPageReloadDelay = fullPageReloadDelay;
        [[NSNotificationCenter defaultCenter] postNotificationName:@"SomethingChanged" object:self];
    }
}

- (void)setEventProcessingDelay:(NSTimeInterval)eventProcessingDelay {
    if (fneq(_eventProcessingDelay, eventProcessingDelay, TIME_EPS)) {
        _eventProcessingDelay = eventProcessingDelay;
        _monitor.eventProcessingDelay = _eventProcessingDelay;
        [[NSNotificationCenter defaultCenter] postNotificationName:@"SomethingChanged" object:self];
    }
}

- (void)setPostProcessingGracePeriod:(NSTimeInterval)postProcessingGracePeriod {
    if (flt(postProcessingGracePeriod, 0.01, TIME_EPS))
        return;
    if (fneq(_postProcessingGracePeriod, postProcessingGracePeriod, TIME_EPS)) {
        _postProcessingGracePeriod = postProcessingGracePeriod;
        [[NSNotificationCenter defaultCenter] postNotificationName:@"SomethingChanged" object:self];
    }
}

- (void)setRubyVersionIdentifier:(NSString *)rubyVersionIdentifier {
    if (_rubyVersionIdentifier != rubyVersionIdentifier) {
        _rubyVersionIdentifier = [rubyVersionIdentifier copy];
        [[NSNotificationCenter defaultCenter] postNotificationName:@"SomethingChanged" object:self];
    }
}


#pragma mark - Paths

- (NSString *)pathForRelativePath:(NSString *)relativePath {
    return [[_path stringByExpandingTildeInPath] stringByAppendingPathComponent:relativePath];
}

- (BOOL)isPathInsideProject:(NSString *)path {
    NSString *root = [_path stringByResolvingSymlinksInPath];
    path = [path stringByResolvingSymlinksInPath];

    NSArray *rootComponents = [root pathComponents];
    NSArray *pathComponents = [path pathComponents];

    NSInteger pathCount = [pathComponents count];
    NSInteger rootCount = [rootComponents count];

    NSInteger numberOfIdenticalComponents = 0;
    while (numberOfIdenticalComponents < MIN(pathCount, rootCount) && [[rootComponents objectAtIndex:numberOfIdenticalComponents] isEqualToString:[pathComponents objectAtIndex:numberOfIdenticalComponents]])
        ++numberOfIdenticalComponents;

    return (numberOfIdenticalComponents == rootCount);
}

- (NSString *)relativePathForPath:(NSString *)path {
    NSString *root = [_path stringByResolvingSymlinksInPath];
    path = [path stringByResolvingSymlinksInPath];

    if ([root isEqualToString:path]) {
        return @"";
    }

    NSArray *rootComponents = [root pathComponents];
    NSArray *pathComponents = [path pathComponents];

    NSInteger pathCount = [pathComponents count];
    NSInteger rootCount = [rootComponents count];

    NSInteger numberOfIdenticalComponents = 0;
    while (numberOfIdenticalComponents < MIN(pathCount, rootCount) && [[rootComponents objectAtIndex:numberOfIdenticalComponents] isEqualToString:[pathComponents objectAtIndex:numberOfIdenticalComponents]])
        ++numberOfIdenticalComponents;

    NSInteger numberOfDotDotComponents = (rootCount - numberOfIdenticalComponents);
    NSInteger numberOfTrailingComponents = (pathCount - numberOfIdenticalComponents);
    NSMutableArray *components = [NSMutableArray arrayWithCapacity:numberOfDotDotComponents + numberOfTrailingComponents];
    for (NSInteger i = 0; i < numberOfDotDotComponents; ++i)
        [components addObject:@".."];
    [components addObjectsFromArray:[pathComponents subarrayWithRange:NSMakeRange(numberOfIdenticalComponents, numberOfTrailingComponents)]];

    return [components componentsJoinedByString:@"/"];
}

- (NSString *)safeDisplayPath {
    NSString *src = [self displayPath];
    return [src stringByReplacingOccurrencesOfRegex:@"\\w" usingBlock:^NSString *(NSInteger captureCount, NSString *const __unsafe_unretained *capturedStrings, const NSRange *capturedRanges, volatile BOOL *const stop) {
        unichar ch = 'a' + (rand() % ('z' - 'a' + 1));
        return [NSString stringWithCharacters:&ch length:1];
    }];
}


#pragma mark - Import Support

- (void)updateImportGraphForPath:(NSString *)relativePath compiler:(Compiler *)compiler {
    NSSet *referencedPathFragments = [compiler referencedPathFragmentsForPath:[_path stringByAppendingPathComponent:relativePath]];

    NSMutableSet *referencedPaths = [NSMutableSet set];
    for (NSString *pathFragment in referencedPathFragments) {
        if ([pathFragment rangeOfString:@"compass"].location == 0 || [pathFragment rangeOfString:@"ZURB-foundation"].location != NSNotFound) {
            _compassDetected = YES;
        }

        NSString *path = [_monitor.tree pathOfBestFileMatchingPathSuffix:pathFragment preferringSubtree:[relativePath stringByDeletingLastPathComponent]];
        if (path) {
            [referencedPaths addObject:path];
        }
    }

    [_importGraph setRereferencedPaths:referencedPaths forPath:relativePath];
}

- (void)updateImportGraphForPath:(NSString *)relativePath {
    NSString *fullPath = [_path stringByAppendingPathComponent:relativePath];
    if (![[NSFileManager defaultManager] fileExistsAtPath:fullPath]) {
        [_importGraph removePath:relativePath collectingPathsToRecomputeInto:nil];
        return;
    }

    if ([self isCompassConfigurationFile:relativePath]) {
        [self scanCompassConfigurationFile:relativePath];
    }

    NSString *extension = [relativePath pathExtension];

    for (Compiler *compiler in [PluginManager sharedPluginManager].compilers) {
        if ([compiler.extensions containsObject:extension]) {
//            CompilationOptions *compilationOptions = [self optionsForCompiler:compiler create:NO];
            [self updateImportGraphForPath:relativePath compiler:compiler];
            return;
        }
    }
}

- (void)updateImportGraphForPaths:(NSSet *)paths {
    for (NSString *path in paths) {
        [self updateImportGraphForPath:path];
    }
    NSLog(@"Incremental import graph update finished. %@", _importGraph);
}

- (void)rebuildImportGraph {
    _compassDetected = NO;
    [_importGraph removeAllPaths];
    NSArray *paths = [_monitor.tree pathsOfFilesMatching:^BOOL(NSString *name) {
        NSString *extension = [name pathExtension];

        // a hack for Compass
        if ([extension isEqualToString:@"rb"] || [extension isEqualToString:@"config"]) {
            return YES;
        }

        for (Compiler *compiler in [PluginManager sharedPluginManager].compilers) {
            if ([compiler.extensions containsObject:extension]) {
//                CompilationOptions *compilationOptions = [self optionsForCompiler:compiler create:NO];
//                CompilationMode mode = compilationOptions.mode;
                if (YES) { //mode == CompilationModeCompile || mode == CompilationModeMiddleware) {
                    return YES;
                }
            }
        }
        return NO;
    }];
    for (NSString *path in paths) {
        [self updateImportGraphForPath:path];
    }
    NSLog(@"Full import graph rebuild finished. %@", _importGraph);
}


#pragma mark - Post-processing

- (NSString *)postProcessingCommand {
    return _postProcessingCommand ?: @"";
}

- (void)setPostProcessingCommand:(NSString *)postProcessingCommand {
    if (postProcessingCommand != _postProcessingCommand) {
        _postProcessingCommand = [postProcessingCommand copy];
        [[NSNotificationCenter defaultCenter] postNotificationName:@"SomethingChanged" object:self];
    }
}

- (void)setPostProcessingScriptName:(NSString *)postProcessingScriptName {
    if (postProcessingScriptName != _postProcessingScriptName) {
        BOOL wasEmpty = (_postProcessingScriptName.length == 0);
        _postProcessingScriptName = [postProcessingScriptName copy];
        if ([_postProcessingScriptName length] > 0 && wasEmpty && !_postProcessingEnabled) {
            [self setPostProcessingEnabled:YES];
        } else if ([_postProcessingScriptName length] == 0 && _postProcessingEnabled) {
            _postProcessingEnabled = NO;
        }
        [self handleCompilationOptionsEnablementChanged];
        [[NSNotificationCenter defaultCenter] postNotificationName:@"SomethingChanged" object:self];
    }
}

- (void)setPostProcessingEnabled:(BOOL)postProcessingEnabled {
    if ([_postProcessingScriptName length] == 0 && postProcessingEnabled) {
        return;
    }
    if (postProcessingEnabled != _postProcessingEnabled) {
        _postProcessingEnabled = postProcessingEnabled;
        [self handleCompilationOptionsEnablementChanged];
        [[NSNotificationCenter defaultCenter] postNotificationName:@"SomethingChanged" object:self];
    }
}

- (UserScript *)postProcessingScript {
    if (_postProcessingScriptName.length == 0)
        return nil;

    NSArray *userScripts = [UserScriptManager sharedUserScriptManager].userScripts;
    for (UserScript *userScript in userScripts) {
        if ([userScript.uniqueName isEqualToString:_postProcessingScriptName])
            return userScript;
    }

    return [[MissingUserScript alloc] initWithName:_postProcessingScriptName];
}


#pragma mark - Excluded paths

- (NSArray *)excludedPaths {
    return _excludedFolderPaths;
}

- (void)addExcludedPath:(NSString *)path {
    if (![_excludedFolderPaths containsObject:path]) {
        [self willChangeValueForKey:@"excludedPaths"];
        [_excludedFolderPaths addObject:path];
        [self didChangeValueForKey:@"excludedPaths"];
        [[NSNotificationCenter defaultCenter] postNotificationName:@"SomethingChanged" object:self];
        [self updateFilter];
    }
}

- (void)removeExcludedPath:(NSString *)path {
    if ([_excludedFolderPaths containsObject:path]) {
        [self willChangeValueForKey:@"excludedPaths"];
        [_excludedFolderPaths removeObject:path];
        [self didChangeValueForKey:@"excludedPaths"];
        [[NSNotificationCenter defaultCenter] postNotificationName:@"SomethingChanged" object:self];
        [self updateFilter];
    }
}


#pragma mark - URLs

- (void)setUrlMasks:(NSArray *)urlMasks {
    if (_urlMasks != urlMasks) {
        _urlMasks = [urlMasks copy];
        [[NSNotificationCenter defaultCenter] postNotificationName:@"SomethingChanged" object:self];
    }
}

- (NSString *)formattedUrlMaskList {
    return [_urlMasks componentsJoinedByString:@", "];
}

- (void)setFormattedUrlMaskList:(NSString *)formattedUrlMaskList {
    self.urlMasks = [formattedUrlMaskList componentsSeparatedByRegex:@"\\s*,\\s*|\\s+"];
}


#pragma mark - Path Options

- (NSArray *)pathOptions {
    NSMutableArray *pathOptions = [NSMutableArray new];
    for (NSString *path in self.tree.folderPaths) {
        [pathOptions addObject:[FilterOption filterOptionWithSubfolder:path]];
    }
    return pathOptions;
}


#pragma mark - Filtering loop prevention hack

- (BOOL)hackhack_shouldFilterFile:(LRFile2 *)file {
    NSDate *date = _fileDatesHack[file.relativePath];
    if (date) {
        NSDate *fileDate = nil;
        BOOL ok = [file.absoluteURL getResourceValue:&fileDate forKey:NSURLContentModificationDateKey error:NULL];
        if (ok && [fileDate compare:date] != NSOrderedDescending) {
            // file modification time is not later than the filtering time
            NSLog(@"NOT applying filter to %@/%@ to avoid an infinite loop", _path, file.relativePath);
            return NO;
        }
    }
    return YES;
}

- (void)hackhack_didFilterFile:(LRFile2 *)file {
    _fileDatesHack[file.relativePath] = [NSDate date];
}

- (void)hackhack_didWriteCompiledFile:(LRFile2 *)file {
    [_fileDatesHack removeObjectForKey:file.relativePath];
}


#pragma mark - Rebuilding

- (void)rebuildAll {
    [_pendingChanges unionSet:[NSSet setWithArray:self.tree.filePaths]];
    _pendingPostProcessing = YES;
    [self processPendingChanges];
}


#pragma mark - Analysis

- (void)setAnalysisInProgress:(BOOL)analysisInProgress forTask:(id)task {
    if (analysisInProgress == [_runningAnalysisTasks containsObject:task])
        return;

    if (analysisInProgress) {
        [_runningAnalysisTasks addObject:task];
        NSLog(@"Analysis started (%d): %@", (int)_runningAnalysisTasks.count, task);
    } else {
        [_runningAnalysisTasks removeObject:task];
        NSLog(@"Analysis finished (%d): %@", (int)_runningAnalysisTasks.count, task);
    }

    BOOL inProgress = (_runningAnalysisTasks.count > 0);
    if (inProgress && !_analysisInProgress) {
        _analysisInProgress = YES;
    } else if (!inProgress && _analysisInProgress) {
        // delay b/c maybe some other task is going to start very soon
        dispatch_async(dispatch_get_main_queue(), ^{
            if ((_runningAnalysisTasks.count == 0) && _analysisInProgress) {
                NSLog(@"Analysis finished notification.");
                _analysisInProgress = NO;
                [self postNotificationName:ProjectAnalysisDidFinishNotification];
            }
        });
    }
}


#pragma mark - Super-advanced options

- (void)_parseSuperAdvancedOptions {
    _quuxMode = NO;
    _forcedStylesheetReloadSpec = nil;

    NSMutableArray *messages = [NSMutableArray new];

    NSArray *items = _superAdvancedOptions;
    NSUInteger count = items.count;
    for (NSUInteger i = 0; i < count; ++i) {
        NSString *option = items[i];
        if ([option isEqualToString:@"quux"]) {
            _quuxMode = YES;
            [messages addObject:@"✓ quux on"];
        } else if ([option isEqualToString:@"reload-all-stylesheets-for"]) {
            if (++i == count) {
                [messages addObject:[NSString stringWithFormat:@"%@ requires an argument", option]];
            } else {
                NSString *value = items[i];
                NSError *__autoreleasing error;
                _forcedStylesheetReloadSpec = [ATPathSpec pathSpecWithString:value syntaxOptions:ATPathSpecSyntaxFlavorExtended error:&error];
                if (!_forcedStylesheetReloadSpec) {
                    [messages addObject:[NSString stringWithFormat:@"%@ parse error: %@", option, error.localizedDescription]];
                } else {
                    [messages addObject:[NSString stringWithFormat:@"✓ %@ = %@", option, _forcedStylesheetReloadSpec.description]];
                }
            }
        } else {
            [messages addObject:[NSString stringWithFormat:@"unknown: %@", option]];
        }
    }

    if (messages.count == 0) {
        [messages addObject:@"No super-advanced options set. Email support to get some? :-)"];
    }

    _superAdvancedOptionsFeedback = [messages copy];
}

- (void)setSuperAdvancedOptions:(NSArray *)superAdvancedOptions {
    if (_superAdvancedOptions != superAdvancedOptions && ![_superAdvancedOptions isEqual:superAdvancedOptions]) {
        _superAdvancedOptions = [superAdvancedOptions copy];
        [self _parseSuperAdvancedOptions];
        [[NSNotificationCenter defaultCenter] postNotificationName:@"SomethingChanged" object:self];
    }
}

- (NSString *)superAdvancedOptionsString {
    return [_superAdvancedOptions quotedArgumentStringUsingBourneQuotingStyle];
}

- (void)setSuperAdvancedOptionsString:(NSString *)superAdvancedOptionsString {
    [self setSuperAdvancedOptions:[superAdvancedOptionsString argumentsArrayUsingBourneQuotingStyle]];
}

- (NSString *)superAdvancedOptionsFeedbackString {
    return [_superAdvancedOptionsFeedback componentsJoinedByString:@" • "];
}

@end
