
#import "ScriptInvocationStep.h"
#import "LRFile2.h"
#import "Project.h"
#import "ToolOutput.h"
#import "Glue.h"

#import "AppState.h"
#import "LRPackageManager.h"
#import "LRPackageType.h"
#import "LRPackageContainer.h"
#import "RubyRuntimeRepository.h"
#import "RubyInstance.h"

#import "ATChildTask.h"
#import "ATFunctionalStyle.h"
#import "NSArray+ATSubstitutions.h"
#import "LRCommandLine.h"
#include "console.h"
#include "stringutil.h"


@implementation ScriptInvocationStep {
    NSMutableDictionary *_substitutions;
    NSMutableDictionary *_files;
    NSMutableDictionary *_environment;
}

- (id)init {
    self = [super init];
    if (self) {
        _substitutions = [NSMutableDictionary new];
        _files = [NSMutableDictionary new];
        _environment = [[NSProcessInfo processInfo].environment mutableCopy];

        [self addValue:[[NSBundle mainBundle] pathForResource:@"LiveReloadNodejs" ofType:nil] forSubstitutionKey:@"node"];
    }
    return self;
}

- (LRFile2 *)fileForKey:(NSString *)key {
    return _files[key];
}

- (void)addValue:(id)value forSubstitutionKey:(NSString *)key {
    _substitutions[[NSString stringWithFormat:@"$(%@)", key]] = value;
}

- (void)addFileValue:(LRFile2 *)file forSubstitutionKey:(NSString *)key {
    _files[key] = file;
    [self addValue:[file.relativePath lastPathComponent] forSubstitutionKey:[NSString stringWithFormat:@"%@_file", key]];
    [self addValue:file.absolutePath forSubstitutionKey:[NSString stringWithFormat:@"%@_path", key]];
    [self addValue:[file.absolutePath stringByDeletingLastPathComponent] forSubstitutionKey:[NSString stringWithFormat:@"%@_dir", key]];
    [self addValue:file.relativePath forSubstitutionKey:[NSString stringWithFormat:@"%@_rel_path", key]];
}

- (void)invoke {
    NSArray *bundledContainers = [[[AppState sharedAppState].packageManager packageTypeNamed:@"gem"].containers filteredArrayUsingBlock:^BOOL(LRPackageContainer *container) {
        return container.containerType == LRPackageContainerTypeBundled;
    }];

    RuntimeInstance *rubyInstance = [[RubyRuntimeRepository sharedRubyManager] instanceIdentifiedBy:_project.rubyVersionIdentifier];
    [self addValue:[rubyInstance launchArgumentsWithAdditionalRuntimeContainers:bundledContainers environment:_environment] forSubstitutionKey:@"ruby"];

    NSArray *cmdline = [_commandLine arrayBySubstitutingValuesFromDictionary:_substitutions];

    //    NSString *pwd = [[NSFileManager defaultManager] currentDirectoryPath];
    //    [[NSFileManager defaultManager] changeCurrentDirectoryPath:projectPath];

    console_printf("Exec: %s", str_collapse_paths([[cmdline quotedArgumentStringUsingBourneQuotingStyle] UTF8String], [_project.path UTF8String]));
    NSLog(@"Exec: %@", [NSString stringWithUTF8String:str_collapse_paths([[cmdline quotedArgumentStringUsingBourneQuotingStyle] UTF8String], [_project.path UTF8String])]);

    NSString *command = cmdline[0];
    NSArray *args = [cmdline subarrayWithRange:NSMakeRange(1, cmdline.count - 1)];
    ATLaunchUnixTaskAndCaptureOutput([NSURL fileURLWithPath:command], args, ATLaunchUnixTaskAndCaptureOutputOptionsIgnoreSandbox|ATLaunchUnixTaskAndCaptureOutputOptionsMergeStdoutAndStderr, @{ATCurrentDirectoryPathKey: _project.path, ATEnvironmentVariablesKey: _environment}, ^(NSString *outputText, NSString *stderrText, NSError *error) {
        _error = error;
        
        if (error) {
            NSLog(@"Error: %@\nOutput:\n%@", [error description], outputText);
            [[Glue glue] postMessage:@{@"service": @"msgparser", @"command": @"parse", @"manifest": self.manifest, @"input": outputText} withReplyHandler:^(NSError *error, NSDictionary *result) {

                NSDictionary *errorMessage = nil;
                for (NSDictionary *message in result[@"messages"]) {
                    if ([message[@"type"] isEqualToString:@"error"]) {
                        errorMessage = message;
                        break;
                    }
                }

                NSString *affectedFile = errorMessage[@"file"] ?: [_files[@"src"] absolutePath];
                if (errorMessage) {
                    _output = [[ToolOutput alloc] initWithCompiler:nil type:ToolOutputTypeError sourcePath:affectedFile line:[errorMessage[@"line"] integerValue] message:errorMessage[@"message"] output:outputText];
                    NSLog(@"Error message: %@", result);
                } else {
                    _output = [[ToolOutput alloc] initWithCompiler:nil type:ToolOutputTypeErrorRaw sourcePath:affectedFile line:0 message:nil output:outputText];
                }

                self.finished = YES;
                if (self.completionHandler)
                    self.completionHandler(self);
            }];
            return;
        }

        self.finished = YES;
        if (self.completionHandler)
            self.completionHandler(self);
    });
}

@end
