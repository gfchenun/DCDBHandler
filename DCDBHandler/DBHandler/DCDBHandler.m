#import "DCDBHandler.h"
#import <FMDB/FMDB.h>
#import <objc/runtime.h>
#import <sqlite3.h>

#define db_name @"DCDB.sqlite"
#define DBLocalizedStr(key) NSLocalizedString(key, @"")

typedef NS_ENUM(NSInteger, DCDbTableCmpResult) {
    DCDbTableNotExist   = 1,
    DCDbTableChanged    = 2,
    DCDbTableTheSame    = 3,
    DCDbTableMigratable = 4,
};

@interface DCDBHandler () {
    FMDatabaseQueue* _dbQueue;
}

@end

@implementation DCDBHandler

#pragma mark -dbFilePath
+ (NSString*)dbFilePath
{
    NSArray* documentArr = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString* dbPath = [[documentArr objectAtIndex:0] stringByAppendingPathComponent:db_name];
    NSLog(@"DB Path = %@",dbPath);
    return dbPath;
}
#pragma mark -sharedInstance
+ (DCDBHandler *)sharedInstance
{
    static DCDBHandler* dbHandler = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dbHandler = [[DCDBHandler alloc] init];
    });
    return dbHandler;
}
/**表名 */
+ (NSString *)tableNameWithModel:(NSObject*)model {
     return [NSString stringWithFormat:@"%@",NSStringFromClass(model.class)];
}
/**忽略基本属性 */
+ (BOOL)ignorePropertyString:(NSString *)propertyStr {
    if ([propertyStr isEqualToString:@"description"] ||
        [propertyStr isEqualToString:@"debugDescription"] ||
        [propertyStr isEqualToString:@"hash"] ||
        [propertyStr isEqualToString:@"superclass"]) {
        return YES;
    }
    return NO;
}
/**检测属性是否可存储 目前支持  NSNumber NSString  NSInteger*/
+ (BOOL)canPropertyBeStored:(NSString*)attrOfProperty
{
    if ([attrOfProperty rangeOfString:@"Array"].location == NSNotFound) {
        if ([attrOfProperty rangeOfString:@"NSNumber"].location != NSNotFound) {
            return YES;
        }
        else if ([attrOfProperty rangeOfString:@"NSString"].location != NSNotFound) {
            return YES;
        }
        // Integer 类型
        else if ([attrOfProperty rangeOfString:@"Tq"].location != NSNotFound) {
            return YES;
        }
    }
    return NO;
}
/**根据对象创建表 */
+ (NSString*)createTableSQLWithModel:(NSObject*)model byPrimaryKey:(NSString*)pKey
{
    unsigned int propertyCount;
    objc_property_t* properties = class_copyAllPropertyList(model.class, &propertyCount);
    NSMutableArray* propertyArr = [NSMutableArray arrayWithCapacity:propertyCount];
    for (unsigned int i = 0; i < propertyCount; i++) {
        objc_property_t property = properties[i];
        
        // 属性
        const char* propertyName = property_getName(property);
        NSString* propertyStr = [NSString stringWithUTF8String:propertyName];
        
        // 去除基本属性
        if ([self.class ignorePropertyString:propertyStr]) {
            continue;
        }
        // 拆解分析属性
        const char* attributeOfProperty = property_getAttributes(property);
        NSString* strOfAttribute = [NSString stringWithUTF8String:attributeOfProperty];
        
        if ([self canPropertyBeStored:strOfAttribute]) {
            if ([strOfAttribute rangeOfString:@"NSNumber"].location != NSNotFound) {
                if ([propertyStr isEqualToString:pKey]) {
                    [propertyArr addObject:[NSString stringWithFormat:@"%@ double PRIMARY KEY", propertyStr]];
                }
                else {
                    [propertyArr addObject:[NSString stringWithFormat:@"%@ double", propertyStr]];
                }
            }
            else if ([strOfAttribute rangeOfString:@"NSString"].location != NSNotFound) {
                if ([propertyStr isEqualToString:pKey]) {
                    [propertyArr addObject:[NSString stringWithFormat:@"%@ text PRIMARY KEY", propertyStr]];
                }
                else {
                    [propertyArr addObject:[NSString stringWithFormat:@"%@ text", propertyStr]];
                }
            }
            else if ([strOfAttribute rangeOfString:@"Tq"].location != NSNotFound) {
                if ([propertyStr isEqualToString:pKey]) {
                    [propertyArr addObject:[NSString stringWithFormat:@"%@ integer PRIMARY KEY", propertyStr]];
                }
                else {
                    [propertyArr addObject:[NSString stringWithFormat:@"%@ integer", propertyStr]];
                }
            }
        }
        // TODOTODOTODO extend the relationship layer
        /*
         NSString *createRelationSQL = [NSString stringWithFormat:@"CREATE TABLE IF NOT EXISTS %@(%@ text,%@ text,%@ text,%@ text)",@"RELATIONTABLE",@"PARIENTTABLENAME",@"PARIENTID",@"SONTABLENAME",@"SONID"];
         if ([strOfAttribute rangeOfString:@"&,N"].location != NSNotFound) {
         [db executeUpdate:createRelationSQL];
         } else {
         
         }
         */
    }
    
    NSString* createTableSQL = [NSString stringWithFormat:@"CREATE TABLE IF NOT EXISTS %@(%@)", [self tableNameWithModel:model], [propertyArr componentsJoinedByString:@","]];
    free(properties);
    return createTableSQL;
}

#pragma mark -init
- (instancetype)init
{
    if (self = [super init]) {
        _dbQueue = [FMDatabaseQueue databaseQueueWithPath:[DCDBHandler dbFilePath]];
        [self createTableVersionDb];
    }
    return self;
}
#pragma mark -insertOrUpdateWithModelArr
- (BOOL)insertOrUpdateWithModelArr:(NSArray*)modelArr byPrimaryKey:(NSString*)pKey
{
    if (modelArr.count > 0) {
        // 检测建表逻辑
        NSObject* model = modelArr.lastObject;
        DCDbTableCmpResult cmpResult = [self verifyCompatibilyForTable:model];
        // for now - if the class property type is not compatible with the current database table
        if (cmpResult == DCDbTableMigratable) {
            // do the migration
            BOOL migrateResult = [self migrateClassTable:model];
            if (migrateResult) {
                // if migration success the means the table are the same as current class
                cmpResult = DCDbTableTheSame;
            }
            else {
                // for the migration failure case, the only left option is to drop the table and create a new version
                cmpResult = DCDbTableChanged;
            }
        }
        
        if (cmpResult == DCDbTableChanged) {
            [self dropModels:[model class]];
        }
        
        if (cmpResult != DCDbTableTheSame) {
            [_dbQueue inDatabase:^(FMDatabase* db) {
                @try {
                    if (![db open]) {
                        NSLog(@"%@", DBLocalizedStr(@"DB_ERROR"));
                        return;
                    }
                    NSString* createSQL = [DCDBHandler createTableSQLWithModel:(NSObject*)model byPrimaryKey:pKey];
                    db.shouldCacheStatements = YES;
                    if (![db executeUpdate:createSQL]) {
                        NSLog(@"create DB fail - %@", createSQL);
                    };
                }
                @catch (NSException* exception) {
                    NSLog(@"%@%@", DBLocalizedStr(@"DB_EXCEPTION"), exception.userInfo.description);
                }
                @finally {
                    [db close];
                }
            }];
        }
    }
    
    // insert or update the data
    for (int i = 0; i < modelArr.count; i++) {
        NSObject* model = [modelArr objectAtIndex:i];
        
        // check if this model exists in the db
        // not sure if this might be a potential efficiency problem, but querying everytime for every object feels pretty weird, so list this as TODO
        BOOL recordExists = NO;
        NSObject* pKeyValue = nil;
        if (pKey != nil) {
            pKeyValue = [self fetchValueFrom:model forKey:pKey];
            if (pKeyValue != nil) {
                NSArray* existingObjs = [NSArray array];
                existingObjs = [self queryWithClass:[model class] key:pKey value:pKeyValue orderByKey:nil desc:NO];
                // TODO - shall we change this to == 1 ?
                if (existingObjs.count > 0) {
                    recordExists = YES;
                }
            }
        }
        
        if (recordExists) {
            [self updateModel:model primaryKey:pKey pKeyValue:pKeyValue];
        }
        else {
            [self insertModel:model];
        }
    }
    
    return YES;
}
- (BOOL)deleteModels:(NSArray*)arrOfmodel withPrimaryKey:(NSString*)key
{
    __block BOOL deleteRst = NO;
    // first get table name & set up the sql command
    NSObject* model = arrOfmodel.lastObject;
    NSString* tableName = [self.class tableNameWithModel:model];
    NSString* sqlString = [NSString stringWithFormat:@"DELETE FROM %@ WHERE %@", tableName, key];
    
    NSObject* pKeyValue = [self fetchValueFrom:model forKey:key];
    if ([pKeyValue isKindOfClass:[NSString class]]) {
        // binding the like parameter doesn't need ''
        sqlString = [sqlString stringByAppendingString:@" LIKE ?"];
    }
    else if ([pKeyValue isKindOfClass:[NSNumber class]]) {
        sqlString = [sqlString stringByAppendingString:@" = ?"];
    }
    else {
        NSLog(@"parameter error");
        return NO;
    }
    
    // execute it
    for (NSObject* delModel in arrOfmodel) {
        NSObject* delMKeyValue = [self fetchValueFrom:delModel forKey:key];
        [_dbQueue inDatabase:^(FMDatabase* db) {
            @try {
                if (![db open]) {
                    NSLog(@"%@", DBLocalizedStr(@"DB_ERROR"));
                    return;
                }
                NSLog(@"executing insert sql - %@", sqlString);
                deleteRst = [db executeUpdate:sqlString, delMKeyValue];
            }
            @catch (NSException* exception) {
                NSLog(@"%@%@", DBLocalizedStr(@"DB_EXCEPTION"), exception.userInfo.description);
            }
            @finally {
                [db close];
            }
        }];
    }
    return deleteRst;
}
- (BOOL) deleteWithClass:(Class)modelClass key:(NSString*)key value:(NSObject*)value {
    __block BOOL deleteRst = NO;
    NSString* tableName = [self.class tableNameWithModel:[modelClass new]];
    NSString* sqlString = [NSString stringWithFormat:@"DELETE FROM %@ WHERE %@", tableName, key];
    if ([value isKindOfClass:[NSString class]]) {
        // binding the like parameter doesn't need ''
        sqlString = [sqlString stringByAppendingString:@" LIKE ?"];
    }
    else if ([value isKindOfClass:[NSNumber class]]) {
        sqlString = [sqlString stringByAppendingString:@" = ?"];
    }
    else {
        NSLog(@"parameter error");
        return NO;
    }
    [_dbQueue inDatabase:^(FMDatabase* db) {
        @try {
            if (![db open]) {
                NSLog(@"%@", DBLocalizedStr(@"DB_ERROR"));
                return;
            }
            NSLog(@"executing insert sql - %@", sqlString);
            deleteRst = [db executeUpdate:sqlString, value];
        }
        @catch (NSException* exception) {
            NSLog(@"%@%@", DBLocalizedStr(@"DB_EXCEPTION"), exception.userInfo.description);
        }
        @finally {
            [db close];
        }
    }];
    return deleteRst;
}
- (NSArray*)queryWithClass:(Class)modelClass key:(NSString*)key value:(NSObject*)value orderByKey:(NSString*)oKey desc:(BOOL)desc
{
    return [self queryWithClass:modelClass key:key value:value page:0 offset:0 orderByKey:oKey desc:desc];
}
- (NSArray*)queryWithClass:(Class)modelClass key:(NSString*)key value:(NSObject*)value page:(NSInteger)page offset:(NSInteger)offset orderByKey:(NSString*)oKey desc:(BOOL)desc
{
    NSMutableArray* resultObjArray = [NSMutableArray array];
    NSString* tableName = [self.class tableNameWithModel:[modelClass new]];
    if (![self isTableExist:tableName]) {
        return resultObjArray;
    }
    NSString* sqlString = @"";
    
    // table
    sqlString = [NSString stringWithFormat:@"SELECT * FROM %@ ", tableName];
    
    // condition
    if (key != nil && value != nil) {
        if ([value isKindOfClass:[NSString class]]) {
            // TODO - currently it's a full match under the case of string scenario, need to consider pattern match by %
            // NOTE - binding the like parameter doesn't need ''
            sqlString = [sqlString stringByAppendingString:[NSString stringWithFormat:@"where %@ LIKE '%@%@%%' ", key,@"%",value]];
        }
        else if ([value isKindOfClass:[NSNumber class]]) {
            sqlString = [sqlString stringByAppendingString:[NSString stringWithFormat:@"where %@=%@ ", key,value]];
        }
        else {
            // object other than nsstring nsnumber is not supported for now
            return resultObjArray;
        }
    }
    // sort
    if (oKey != nil) {
        sqlString = [sqlString stringByAppendingString:[NSString stringWithFormat:@"order by %@ %@", oKey, desc ? @"DESC" : @"ASC"]];
    }
    
    if (offset > 0) {
        sqlString = [sqlString stringByAppendingString:[NSString stringWithFormat:@" limit %@ offset %@",@(offset),@(page*offset)]];
    }
    
    [_dbQueue inDatabase:^(FMDatabase* db) {
        @try {
            if (![db open]) {
                NSLog(@"%@", DBLocalizedStr(@"DB_ERROR"));
                return;
            }
            NSLog(@"sqlString = %@", sqlString);
            FMResultSet* result = [db executeQuery:sqlString, value];
            while ([result next]) {
                id<NSObject> obj = [self objectFromFMResult:result byClass:modelClass];
                if (obj != nil) {
                    [resultObjArray addObject:obj];
                }
            }
        }
        @catch (NSException* exception) {
            NSLog(@"%@%@", DBLocalizedStr(@"DB_EXCEPTION"), exception.userInfo.description);
        }
        @finally {
            [db close];
        }
    }];
    return resultObjArray;
}
- (NSArray*)queryWithClass:(Class)modelClass key:(NSString*)key values:(NSArray*)values orderByKey:(NSString*)oKey desc:(BOOL)desc {
    
    NSString *appendValue = [values componentsJoinedByString:@","];
    NSString *sqlString = [NSString stringWithFormat:@"where %@ IN (%@) ", key,appendValue];
    // sort
    if (oKey != nil) {
        sqlString = [sqlString stringByAppendingString:[NSString stringWithFormat:@"order by %@ %@", oKey, desc ? @"DESC" : @"ASC"]];
    }
    return [self queryWithClass:modelClass appendingSQLString:sqlString];
}
- (NSArray*)queryWithClass:(Class)modelClass appendingSQLString:(NSString *)appendingString {
    NSMutableArray* resultObjArray = [NSMutableArray array];
    NSString* tableName = [self.class tableNameWithModel:[modelClass new]];
    if (![self isTableExist:tableName]) {
        return resultObjArray;
    }
    NSString* sqlString = [NSString stringWithFormat:@"SELECT * FROM %@ %@", tableName,appendingString];
    
    [_dbQueue inDatabase:^(FMDatabase* db) {
        @try {
            if (![db open]) {
                NSLog(@"%@", DBLocalizedStr(@"DB_ERROR"));
                return;
            }
            FMResultSet* result = [db executeQuery:sqlString];
            while ([result next]) {
                id<NSObject> obj = [self objectFromFMResult:result byClass:modelClass];
                if (obj != nil) {
                    [resultObjArray addObject:obj];
                }
            }
        }
        @catch (NSException* exception) {
            NSLog(@"%@%@", DBLocalizedStr(@"DB_EXCEPTION"), exception.userInfo.description);
        }
        @finally {
            [db close];
        }
    }];
    return resultObjArray;
}

- (NSNumber*)queryFunction:(NSString *)func withClass:(Class)modelClass key:(NSString*)key appendingSQLString:(NSString *)appendingString {
    NSString* tableName = [self.class tableNameWithModel:[modelClass new]];
    if (![self isTableExist:tableName]) {
        return nil;
    }
    NSString* sqlString = [NSString stringWithFormat:@"SELECT %@(%@) FROM %@ ", func,key,tableName];
    if (appendingString) {
        sqlString = [sqlString stringByAppendingString:appendingString];
    }
    __block NSNumber *value = [[NSNumber alloc] init];
    [_dbQueue inDatabase:^(FMDatabase* db) {
        @try {
            if (![db open]) {
                return;
            }
            FMResultSet* result = [db executeQuery:sqlString];
            NSLog(@"sqlString = %@", sqlString);
            while ([result next]) {
                value = [result objectForColumnIndex:0];
            }
        }
        @catch (NSException* exception) {
            NSLog(@"%@", exception.userInfo.description);
        }
        @finally {
            [db close];
        }
    }];
    return value;
}

- (BOOL)dropModels:(Class)modelClass
{
    NSString* createTableSQL = [NSString stringWithFormat:@"DROP TABLE IF EXISTS %@", [self.class tableNameWithModel:[modelClass new]]];
    
    __block BOOL dropResult = NO;
    [_dbQueue inDatabase:^(FMDatabase* db) {
        @try {
            if (![db open]) {
                NSLog(@"%@", DBLocalizedStr(@"DB_ERROR"));
                return;
            }
            dropResult = [db executeUpdate:createTableSQL];
        }
        @catch (NSException* exception) {
            NSLog(@"%@%@", DBLocalizedStr(@"DB_EXCEPTION"), exception.userInfo.description);
        }
        @finally {
            [db close];
        }
    }];
    
    return dropResult;
}
#pragma mark private funcitons - shall NOT be public
- (BOOL)insertModel:(NSObject*)model
{
    __block BOOL insertResult = NO;
    // first get table name
    NSString* tableName = [self.class tableNameWithModel:model];
    NSString* sqlString = [NSString stringWithFormat:@"INSERT INTO %@ VALUES(", tableName];
    
    // enum through the properties and set up 1 sql command 2 parameter array
    unsigned int propertyCount;
    objc_property_t* properties = class_copyAllPropertyList([model class], &propertyCount);
    NSMutableArray* arrOfValue = [[NSMutableArray alloc] init];
    for (unsigned int i = 0; i < propertyCount; i++) {
        objc_property_t property = properties[i];
        // 属性
        const char* propertyName = property_getName(property);
        NSString* propertyStr = [NSString stringWithUTF8String:propertyName];
        
        // 去除基本属性
        if ([self.class ignorePropertyString:propertyStr]) {
            continue;
        }
        
        const char* attributeOfProperty = property_getAttributes(property);
        NSString* strOfAttribute = [NSString stringWithUTF8String:attributeOfProperty];
        
        if (![[self class] canPropertyBeStored:strOfAttribute]) {
            continue;
        }
        
        sqlString = [sqlString stringByAppendingString:@"?,"];
        
        NSObject* pKeyValue = [self fetchValueFrom:model forKey:propertyStr];
        [arrOfValue addObject:pKeyValue == nil ? @"" : pKeyValue];
    }
    
    sqlString = [sqlString substringToIndex:[sqlString length] - 1];
    
    sqlString = [sqlString stringByAppendingString:@")"];
    
    // execute it
    [_dbQueue inDatabase:^(FMDatabase* db) {
        @try {
            if (![db open]) {
                NSLog(@"%@", DBLocalizedStr(@"DB_ERROR"));
                return;
            }
            NSLog(@"executing insert sql - %@", sqlString);
            insertResult = [db executeUpdate:sqlString withArgumentsInArray:arrOfValue];
        }
        @catch (NSException* exception) {
            NSLog(@"%@%@", DBLocalizedStr(@"DB_EXCEPTION"), exception.userInfo.description);
        }
        @finally {
            [db close];
        }
    }];
    
    free(properties);
    return insertResult;
}
- (BOOL)updateModel:(NSObject*)model primaryKey:(NSString*)pkey pKeyValue:(NSObject*)value
{
    __block BOOL insertResult = NO;
    // first get table name
    NSString* tableName = [self.class tableNameWithModel:model];
    NSString* sqlString = [NSString stringWithFormat:@"UPDATE %@ set ", tableName];
    
    NSMutableArray* keyValuePairArr = [NSMutableArray array];
    // enum through the properties and set up 1 sql command 2 parameter array
    unsigned int propertyCount;
    objc_property_t* properties = class_copyAllPropertyList([model class], &propertyCount);
    NSMutableArray* arrOfValue = [[NSMutableArray alloc] init];
    for (unsigned int i = 0; i < propertyCount; i++) {
        objc_property_t property = properties[i];
        // 属性
        const char* propertyName = property_getName(property);
        NSString* propertyStr = [NSString stringWithUTF8String:propertyName];
        // 去除基本属性
        if ([self.class ignorePropertyString:propertyStr]) {
            continue;
        }
        const char* attributeOfProperty = property_getAttributes(property);
        NSString* strOfAttribute = [NSString stringWithUTF8String:attributeOfProperty];
        
        if (![[self class] canPropertyBeStored:strOfAttribute]) {
            continue;
        }
        
        [keyValuePairArr addObject:[NSString stringWithFormat:@"%@ = ?", propertyStr]];
        
        NSObject* pKeyValue = [self fetchValueFrom:model forKey:propertyStr];
        [arrOfValue addObject:pKeyValue == nil ? @"" : pKeyValue];
    }
    sqlString = [sqlString stringByAppendingString:[keyValuePairArr componentsJoinedByString:@","]];
    sqlString = [sqlString stringByAppendingString:[NSString stringWithFormat:@"where %@ = ?", pkey]];
    [arrOfValue addObject:value];
    
    // execute it
    [_dbQueue inDatabase:^(FMDatabase* db) {
        @try {
            if (![db open]) {
                NSLog(@"%@", DBLocalizedStr(@"DB_ERROR"));
                return;
            }
            
            NSLog(@"executing insert sql - %@", sqlString);
            insertResult = [db executeUpdate:sqlString withArgumentsInArray:arrOfValue];
            // do we need to close FMResultSet? or DB close is sufficient?
        }
        @catch (NSException* exception) {
            NSLog(@"%@%@", DBLocalizedStr(@"DB_EXCEPTION"), exception.userInfo.description);
        }
        @finally {
            [db close];
        }
    }];
    free(properties);
    return insertResult;
}
#pragma mark -buildSetSelectorWithProperty
+ (SEL)buildSelectorWithProperty:(NSString*)property
{
    NSString* propertySEL = [NSString stringWithFormat:@"set%@%@:", [property substringToIndex:1].uppercaseString, [property substringFromIndex:1]];
    SEL setSelector = NSSelectorFromString(propertySEL);
    return setSelector;
}

+ (SEL)buildGetSelectorWithProperty:(NSString*)property
{
    SEL getSelector = NSSelectorFromString(property);
    return getSelector;
}

- (id<NSObject>)objectFromFMResult:(FMResultSet*)resultSet byClass:(Class)modelClass
{
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    
    // first create the target class object
    if (![modelClass isSubclassOfClass:[NSObject class]]) {
        return nil;
    }
    
    id<NSObject> resultObj = [[modelClass alloc] init];
    
    // them map data from result to the target class object
    unsigned int propertyCount;
    objc_property_t* properties = class_copyAllPropertyList(modelClass, &propertyCount);
    for (unsigned int i = 0; i < propertyCount; i++) {
        objc_property_t property = properties[i];
        
        // 属性
        const char* propertyName = property_getName(property);
        NSString* propertyStr = [NSString stringWithUTF8String:propertyName];
        // 去除基本属性
        if ([self.class ignorePropertyString:propertyStr]) {
            continue;
        }
        // 拆解分析属性
        const char* attributeOfProperty = property_getAttributes(property);
        NSString* strOfAttribute = [NSString stringWithUTF8String:attributeOfProperty];
        
        if ([[self class] canPropertyBeStored:strOfAttribute]) {
            SEL setSEL = [[self class] buildSelectorWithProperty:propertyStr];
            // put the valide property into the class
            if ([strOfAttribute rangeOfString:@"NSNumber"].location != NSNotFound) {
                NSNumber* number = nil;
                
                NSString* resultStr = (NSString*)[resultSet stringForColumn:propertyStr];
                if (resultStr.length > 0) {
                    number = [NSNumber numberWithDouble:resultStr.doubleValue];
                }
                //double rstDoulbleValue = [resultSet doubleForColumn:propertyStr];
                if ([resultObj respondsToSelector:setSEL]) {
                    [resultObj performSelector:setSEL withObject:number];
                }
            }
            else if ([strOfAttribute rangeOfString:@"NSString"].location != NSNotFound) {
                NSString* rstStringValue = [resultSet stringForColumn:propertyStr];
                if ([resultObj respondsToSelector:setSEL]) {
                    [resultObj performSelector:setSEL withObject:rstStringValue];
                }
            }
            else if ([strOfAttribute rangeOfString:@"Tq"].location != NSNotFound) {
                
                NSInteger rstIntValue = [resultSet intForColumn:propertyStr];
                if (rstIntValue > 0) {
                    if ([resultObj respondsToSelector:setSEL]) {
                        NSMethodSignature* signature = [resultObj.class instanceMethodSignatureForSelector:setSEL];
                        NSInvocation* invocation = [NSInvocation invocationWithMethodSignature:signature];
                        invocation.selector = setSEL;
                        invocation.target = resultObj;
                        [invocation setArgument:&rstIntValue atIndex:2];
                        [invocation invoke];
                    }
                }
            }
        }
    }
#pragma clang diagnostic pop
    free(properties);
    // let's give it back
    return resultObj;
}
- (NSObject*)fetchValueFrom:(NSObject*)model forKey:(NSString*)key
{
    SEL getterSel = [[self class] buildGetSelectorWithProperty:key];
    if ([model respondsToSelector:getterSel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        if ([self verifyProprtryTypeIsIntegerFrom:model forKey:key]) {
            NSInteger obj = (NSInteger)[model performSelector:getterSel];
            return @(obj);
            //            NSInteger
        }
        else {
            return [model performSelector:getterSel];
        }
#pragma clang diagnostic pop
    }
    return nil;
}

- (BOOL)verifyProprtryTypeIsIntegerFrom:(NSObject*)model forKey:(NSString*)key
{
    objc_property_t property = class_getProperty(model.class, [key UTF8String]);
    const char* attributeOfProperty = property_getAttributes(property);
    NSString* strOfAttribute = [NSString stringWithUTF8String:attributeOfProperty];
    if ([strOfAttribute rangeOfString:@"Tq"].location == NSNotFound) {
        return NO;
    }
    else {
        return YES;
    }
}
// currently the compatibility check is quite weak, only check for the number of columns
// for future implementation of compatibility and data migration, check .h file header corresponding section
- (DCDbTableCmpResult)verifyCompatibilyForTable:(NSObject*)model
{
    if ([model isKindOfClass:[DCDBTableVersion class]])
        return DCDbTableTheSame;
    
    if (![self isTableExist:[self.class tableNameWithModel:model]]) {
        return DCDbTableNotExist;
    }
    
    // try the migration version first
    if ([model.class conformsToProtocol:@protocol(DCDBMigrationProtocol)]) {
        NSNumber* currentVersion = (NSNumber*)[model performSelector:@selector(dataVersionOfClass)];
        NSUInteger dbVersion = [self getInDbClassVersion:model.class];
        
        if (currentVersion.unsignedIntegerValue != dbVersion) {
            return DCDbTableMigratable;
        }
    }
    
    unsigned int propertyCount;
    unsigned int storePropertyCount = 0;
    objc_property_t* properties = class_copyAllPropertyList(model.class, &propertyCount);
    for (unsigned int i = 0; i < propertyCount; i++) {
        objc_property_t property = properties[i];
        // 属性
        const char* propertyName = property_getName(property);
        NSString* propertyStr = [NSString stringWithUTF8String:propertyName];
        // 去除基本属性
        if ([self.class ignorePropertyString:propertyStr]) {
            continue;
        }
        // 拆解分析属性
        const char* attributeOfProperty = property_getAttributes(property);
        NSString* strOfAttribute = [NSString stringWithUTF8String:attributeOfProperty];
        
        if ([[self class] canPropertyBeStored:strOfAttribute]) {
            storePropertyCount++;
        }
    }
    int currentTableColNo = [self tableColumnCount:[self.class tableNameWithModel:model]];
    if (currentTableColNo != storePropertyCount) {
        return DCDbTableChanged;
    }
    free(properties);
    return DCDbTableTheSame;
}
- (BOOL)isTableExist:(NSString*)tableName
{
    NSString* checkSql = [NSString stringWithFormat:@"SELECT name FROM sqlite_master WHERE type='table' AND name='%@' ", tableName];
    __block BOOL exist = NO;
    
    [_dbQueue inDatabase:^(FMDatabase* db) {
        @try {
            if (![db open]) {
                NSLog(@"%@", DBLocalizedStr(@"DB_ERROR"));
                return;
            }
            FMResultSet* resultSet = [db executeQuery:checkSql];
            if (resultSet.next) {
                exist = YES;
            }
        }
        @catch (NSException* exception) {
            NSLog(@"%@%@", DBLocalizedStr(@"DB_EXCEPTION"), exception.userInfo.description);
        }
        @finally {
            [db close];
        }
    }];
    
    return exist;
}
- (unsigned int)tableColumnCount:(NSString*)tableName
{
    NSString* schemaSql = [NSString stringWithFormat:@"PRAGMA table_info(%@)", tableName];
    
    __block unsigned int countOfCol = 0;
    // execute it
    [_dbQueue inDatabase:^(FMDatabase* db) {
        @try {
            if (![db open]) {
                NSLog(@"%@", DBLocalizedStr(@"DB_ERROR"));
                return;
            }
            [db executeStatements:schemaSql withResultBlock:^int(NSDictionary* resultsDictionary) {
                countOfCol++;
                return SQLITE_OK;
            }];
        }
        @catch (NSException* exception) {
            NSLog(@"%@%@", DBLocalizedStr(@"DB_EXCEPTION"), exception.userInfo.description);
        }
        @finally {
            [db close];
        }
    }];
    
    return countOfCol;
}
#pragma mark table of table version related functions

- (void)createTableVersionDb
{
    DCDBTableVersion*tableVersion = [[DCDBTableVersion alloc] init];
    NSString * tableName = NSStringFromClass([DCDBTableVersion class]);
    if (![self isTableExist:tableName]) {
        [_dbQueue inDatabase:^(FMDatabase* db) {
            @try {
                if (![db open]) {
                    NSLog(@"%@", DBLocalizedStr(@"DB_ERROR"));
                    return;
                }
                NSString* createSQL = [DCDBHandler createTableSQLWithModel:tableVersion byPrimaryKey:nil];
                db.shouldCacheStatements = YES;
                if (![db executeUpdate:createSQL]) {
                    NSLog(@"create DB fail - %@", createSQL);
                };
            }
            @catch (NSException* exception) {
                NSLog(@"%@%@", DBLocalizedStr(@"DB_EXCEPTION"), exception.userInfo.description);
            }
            @finally {
                [db close];
            }
        }];
    }
}

- (void)updateClassVersion:(NSObject*)model
{
    DCDBTableVersion* tVersion = [[DCDBTableVersion alloc] init];
    tVersion.tablename = [self.class tableNameWithModel:tVersion];
    NSNumber* version = (NSNumber*)[model performSelector:@selector(dataVersionOfClass)];
    tVersion.version = version;
    [self insertOrUpdateWithModelArr:@[ tVersion ] byPrimaryKey:@"tablename"];
}

- (NSUInteger)getInDbClassVersion:(Class)modelClass
{
    NSString* tableName = [self.class tableNameWithModel:[modelClass new]];
    NSArray* tVersionArray = [self queryWithClass:[DCDBTableVersion class] key:@"tablename" value:tableName orderByKey:nil desc:NO];
    if (tVersionArray != nil && [tVersionArray count] == 1) {
        DCDBTableVersion* tVersion = tVersionArray.lastObject;
        return tVersion.version.integerValue;
    }
    return 0;
}

- (BOOL)migrateClassTable:(NSObject*)model
{
    // just a double check
    if (![model.class conformsToProtocol:@protocol(DCDBMigrationProtocol)]) {
        return NO;
    }
    
    // this part of the code is a little bit duplicated, i just wanna the function to be totally seperated as we may face quite a lot of change
    NSNumber* currentVersion = (NSNumber*)[model performSelector:@selector(dataVersionOfClass)];
    NSUInteger dbVersion = [self getInDbClassVersion:model.class];
    
    if (currentVersion.unsignedIntegerValue == dbVersion) {
        return YES;
    }
    // NOTE FOR NOW WE ONLY support upgrade, but downgrade shall be supported ;-) it's easy, i just need time
    if (currentVersion.unsignedIntegerValue < dbVersion) {
        return NO;
    }
    
    // let's get the delta information for add/delete/update
    NSMutableDictionary* totalAddSet = [NSMutableDictionary dictionary];
    NSMutableDictionary* totalUpdateSet = [NSMutableDictionary dictionary];
    NSMutableDictionary* totaldeleteSet = [NSMutableDictionary dictionary];
    
    for (NSUInteger i = dbVersion + 1; i <= currentVersion.unsignedIntegerValue; i++) {
        NSArray* addArray = [model performSelector:@selector(addedKeysForVersion:) withObject:[NSNumber numberWithUnsignedInteger:i]];
        NSArray* deleleArray = [model performSelector:@selector(deletedKeysForVersion:) withObject:[NSNumber numberWithUnsignedInteger:i]];
        NSMutableDictionary* updateDic = [NSMutableDictionary dictionaryWithDictionary:[model performSelector:@selector(renamedKeysForVersion:) withObject:[NSNumber numberWithUnsignedInteger:i]]];
        
        // quite complicated here, i almost give up on this one... so here is the scenario
        // Short version:
        // for all the changes from orignial to target, we would like a final change to summarize
        
        // Long version:
        // For all the   ADDS     UPDATES     DELETES
        //               add1      update1    delete1
        //               add2      update2    delete2
        //               ..        ..         ..
        //               addn      updaten    deleten
        
        // the first thing for any addx, deletex and updatex is merge them with previous changes So -
        // 1. ADDs minus deletex, if a match is found, then both of the item can be removed
        // 2. DELETES minus addx, if a match is found, then both of the item can be removed - think about 1&2, quite a lot of cases actually ;-D
        // 3. ADDs merge with updatex, if a key to key match is found, the key in ADDs will be replaced by updatex's value, then remove it from updatex
        // 4. UPDATES minus deletex, in case the updated key is removed. then remove the update item and change deletex to the original item.
        
        // after above merges then put addx into ADDS, updatex into UPDATES, deletex into DELETES
        
        NSMutableArray* dArray = [NSMutableArray arrayWithArray:deleleArray];
        NSMutableArray* aArray = [NSMutableArray arrayWithArray:addArray];
        
        [totalAddSet minusByKeyArray:dArray modifyInput:YES];
        [totaldeleteSet minusByKeyArray:aArray modifyInput:YES];
        [totalAddSet mergeWithUpdateDic:updateDic];
        [totalUpdateSet minusByKeyArrayUseValue:dArray modifyInput:YES];
        
        [totalAddSet addByKeyArray:aArray];
        [totaldeleteSet addByKeyArray:dArray];
        [totalUpdateSet addDic:updateDic];
    }
    
    // ok - after having the final ADDS DELETS UPDATES, let's operate on the db
    // due to the fact that sqlite doesn't support the alter for column name or delete column - here is my approach to do the dirty job
    
    // first get all the target class properties
    unsigned int propertyCount;
    objc_property_t* properties = class_copyAllPropertyList(model.class, &propertyCount);
    NSMutableArray* propertyArr = [NSMutableArray arrayWithCapacity:propertyCount];
    for (unsigned int i = 0; i < propertyCount; i++) {
        objc_property_t property = properties[i];
        
        // 属性
        const char* propertyName = property_getName(property);
        NSString* propertyStr = [NSString stringWithUTF8String:propertyName];
        // 去除基本属性
        if ([self.class ignorePropertyString:propertyStr]) {
            continue;
        }
        // 拆解分析属性
        const char* attributeOfProperty = property_getAttributes(property);
        NSString* strOfAttribute = [NSString stringWithUTF8String:attributeOfProperty];
        
        if ([[self class] canPropertyBeStored:strOfAttribute]) {
            if ([strOfAttribute rangeOfString:@"NSNumber"].location != NSNotFound) {
                [propertyArr addObject:[NSString stringWithFormat:@"%@ double", propertyStr]];
            }
            else if ([strOfAttribute rangeOfString:@"NSString"].location != NSNotFound) {
                [propertyArr addObject:[NSString stringWithFormat:@"%@ text", propertyStr]];
            }
            else if ([strOfAttribute rangeOfString:@"Tq"].location != NSNotFound) {
                [propertyArr addObject:[NSString stringWithFormat:@"%@ integer", propertyStr]];
            }
            
        }
    }
    
    // dump all the data from origial table and creat objects from that
    NSString* queryString = [NSString stringWithFormat:@"SELECT * FROM %@ ", [self.class tableNameWithModel:model]];
    NSMutableArray* mergedObjects = [NSMutableArray array];
    [_dbQueue inDatabase:^(FMDatabase* db) {
        @try {
            if (![db open]) {
                NSLog(@"%@", DBLocalizedStr(@"DB_ERROR"));
                return;
            }
            FMResultSet* result = [db executeQuery:queryString];
            while ([result next]) {
                // try load it do new class
                // create a object of new class
                id<NSObject> resultObj = [[model.class alloc] init];
                
                // first get the properties of new class
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                for (unsigned int i = 0; i < propertyCount; i++) {
                    objc_property_t property = properties[i];
                    
                    const char* propertyName = property_getName(property);
                    NSString* propertyStr = [NSString stringWithUTF8String:propertyName];
                    // 去除基本属性
                    if ([self.class ignorePropertyString:propertyStr]) {
                        continue;
                    }
                    const char* attributeOfProperty = property_getAttributes(property);
                    NSString* strOfAttribute = [NSString stringWithUTF8String:attributeOfProperty];
                    if ([[self class] canPropertyBeStored:strOfAttribute]) {
                        __block NSString* origKey = propertyStr;
                        [totalUpdateSet enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL* stop) {
                            if ([(NSString*)obj isEqualToString:origKey]) {
                                origKey = (NSString*)key;
                                *stop = YES;
                            }
                        }];
                        SEL setSEL = [[self class] buildSelectorWithProperty:propertyStr];
                        // put the valide property into the class
                        if ([strOfAttribute rangeOfString:@"NSNumber"].location != NSNotFound) {
                            double rstDoulbleValue = [result doubleForColumn:origKey];
                            if ([resultObj respondsToSelector:setSEL]) {
                                [resultObj performSelector:setSEL withObject:[NSNumber numberWithDouble:rstDoulbleValue]];
                            }
                        }
                        else if ([strOfAttribute rangeOfString:@"NSString"].location != NSNotFound) {
                            NSString* rstStringValue = [result stringForColumn:origKey];
                            if ([resultObj respondsToSelector:setSEL]) {
                                [resultObj performSelector:setSEL withObject:rstStringValue == nil ? @"" : rstStringValue];
                            }
                        }
                        else if ([strOfAttribute rangeOfString:@"Tq"].location != NSNotFound) {
                            NSInteger rstIntValue = [result intForColumn:origKey];
                            if ([resultObj respondsToSelector:setSEL]) {
                                if ([resultObj respondsToSelector:setSEL]) {
                                    NSMethodSignature* signature = [resultObj.class instanceMethodSignatureForSelector:setSEL];
                                    NSInvocation* invocation = [NSInvocation invocationWithMethodSignature:signature];
                                    invocation.selector = setSEL;
                                    invocation.target = resultObj;
                                    [invocation setArgument:&rstIntValue atIndex:2];
                                    [invocation invoke];
                                }
                            }
                        }
                    }
                }
#pragma clang diagnostic pop
                [mergedObjects addObject:resultObj];
            }
        }
        @catch (NSException* exception) {
            NSLog(@"%@%@", DBLocalizedStr(@"DB_EXCEPTION"), exception.userInfo.description);
        }
        @finally {
            [db close];
        }
    }];
    
    // drop the old table
    [self dropModels:model.class];
    
    // create new
    NSString* createTableSQL = [NSString stringWithFormat:@"CREATE TABLE IF NOT EXISTS %@(%@)", [self.class tableNameWithModel:model], [propertyArr componentsJoinedByString:@","]];
    [_dbQueue inDatabase:^(FMDatabase* db) {
        @try {
            if (![db open]) {
                NSLog(@"%@", DBLocalizedStr(@"DB_ERROR"));
                return;
            }
            db.shouldCacheStatements = YES;
            if (![db executeUpdate:createTableSQL]) {
                NSLog(@"create DB fail - %@", createTableSQL);
            };
        }
        @catch (NSException* exception) {
            NSLog(@"%@%@", DBLocalizedStr(@"DB_EXCEPTION"), exception.userInfo.description);
        }
        @finally {
            [db close];
        }
    }];
    
    // insert data in
    for (int i = 0; i < mergedObjects.count; i++) {
        NSObject* model = [mergedObjects objectAtIndex:i];
        
        NSString* primaryKey = [model performSelector:@selector(primaryKey)];
        // check if this model exists in the db
        // not sure if this might be a potential efficiency problem, but querying everytime for every object feels pretty weird, so list this as TODO
        BOOL recordExists = NO;
        NSObject* pKeyValue = nil;
        if (primaryKey != nil) {
            pKeyValue = [self fetchValueFrom:model forKey:primaryKey];
            if (pKeyValue != nil) {
                NSArray* existingObjs = [NSArray array];
                existingObjs = [self queryWithClass:[model class] key:primaryKey value:pKeyValue orderByKey:nil desc:NO];
                // TODO - shall we change this to == 1 ?
                if (existingObjs.count > 0) {
                    recordExists = YES;
                }
            }
        }
        if (recordExists) {
            [self updateModel:model primaryKey:primaryKey pKeyValue:pKeyValue];
        }
        else {
            [self insertModel:model];
        }
    }
    
    // update table version information
    DCDBTableVersion* newDBTVersion = [[DCDBTableVersion alloc] init];
    newDBTVersion.tablename = [self.class tableNameWithModel:model];
    newDBTVersion.version = currentVersion;
    [self insertOrUpdateWithModelArr:@[ newDBTVersion ] byPrimaryKey:@"tablename"];
    
    free(properties);
    return YES;
}

- (NSString*)fetchPropertyType:(Class)cls byName:(NSString*)name
{
    unsigned int propertyCount;
    NSString* propertyType;
    objc_property_t* properties = class_copyAllPropertyList(cls, &propertyCount);
    for (unsigned int i = 0; i < propertyCount; i++) {
        objc_property_t property = properties[i];
        const char* propertyName = property_getName(property);
        NSString* propertyStr = [NSString stringWithUTF8String:propertyName];
        // 去除基本属性
        if ([self.class ignorePropertyString:propertyStr]) {
            continue;
        }
        if ([propertyStr isEqualToString:name]) {
            const char* attributeOfProperty = property_getAttributes(property);
            NSString* strOfAttribute = [NSString stringWithUTF8String:attributeOfProperty];
            if ([[self class] canPropertyBeStored:strOfAttribute]) {
                if ([strOfAttribute rangeOfString:@"NSNumber"].location != NSNotFound) {
                    propertyType = @"double";
                }
                else if ([strOfAttribute rangeOfString:@"NSString"].location != NSNotFound) {
                    propertyType = @"text";
                }
                else if ([strOfAttribute rangeOfString:@"Tq"].location != NSNotFound) {
                    propertyType = @"integer";
                }
            }
            break;
        }
    }
    free(properties);
    return propertyType;
}

#pragma mark extension for copy_propertyList

// copies the property list util it reaches the NSObject
// Attention - same as class_copyPropertyList, the returned objc_property_t * needs to be explictly freed by caller.
objc_property_t* class_copyAllPropertyList(Class cls, unsigned int* outCount)
{
    unsigned int propertyCountInAll = 0;
    objc_property_t* currentProperties = NULL;
    Class currentCls = cls;
    while (currentCls != [NSObject class]) {
        unsigned int propertyCount;
        objc_property_t* properties = class_copyPropertyList(currentCls, &propertyCount);
        if (currentProperties == NULL) {
            propertyCountInAll += propertyCount;
            currentProperties = malloc(propertyCountInAll * sizeof(objc_property_t));
            if (currentProperties != NULL) {
                for (int i = 0; i < propertyCount; i++) {
                    currentProperties[i] = properties[i];
                }
            }
        }
        else {
            unsigned int oldCount = propertyCountInAll;
            propertyCountInAll += propertyCount;
            currentProperties = realloc(currentProperties, propertyCountInAll * sizeof(objc_property_t));
            for (int i = oldCount; i < propertyCountInAll; i++) {
                currentProperties[i] = properties[i - oldCount];
            }
        }
        currentCls = class_getSuperclass(currentCls);
        free(properties);
    }
    *outCount = propertyCountInAll;
    return currentProperties;
}


@end

@implementation NSMutableDictionary (SetOperation)

- (NSMutableDictionary*)addDic:(NSDictionary*)addDictionary
{
    if (addDictionary == nil || [addDictionary count] == 0) {
        return self;
    }
    
    [addDictionary enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL* stop) {
        __block BOOL foundmatch = NO;
        [self enumerateKeysAndObjectsUsingBlock:^(id tmpKey, id tmpObj, BOOL* stop) {
            if ([(NSString*)tmpObj isEqualToString:key]) {
                foundmatch = YES;
                *stop = YES;
                [self setObject:obj forKey:tmpKey];
            }
        }];
        
        if (!foundmatch)
            [self setObject:obj forKey:key];
    }];
    
    return self;
}

- (NSMutableDictionary*)minusDic:(NSDictionary*)minusDictionary
{
    if (minusDictionary == nil || [minusDictionary count] == 0) {
        return self;
    }
    
    [minusDictionary enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL* stop) {
        [self removeObjectForKey:key];
    }];
    
    return self;
}

- (NSMutableDictionary*)addByKeyArray:(NSArray*)keyArray
{
    if (keyArray == nil || [keyArray count] == 0) {
        return self;
    }
    
    [keyArray enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL* stop) {
        if ([obj isKindOfClass:[NSString class]]) {
            [self setObject:@"" forKey:obj];
        }
    }];
    
    return self;
}

- (NSMutableDictionary*)minusByKeyArray:(NSMutableArray*)keyArray modifyInput:(BOOL)mInput
{
    if (keyArray == nil || [keyArray count] == 0) {
        return self;
    }
    
    for (int i = 0; i < [keyArray count]; i++) {
        id obj = [keyArray objectAtIndex:i];
        if ([obj isKindOfClass:[NSString class]]) {
            if ([self objectForKey:obj] != nil) {
                [self removeObjectForKey:obj];
                if (mInput) {
                    [keyArray removeObjectAtIndex:i];
                    i--;
                }
            }
        }
    }
    
    return self;
}

- (NSMutableDictionary*)mergeWithUpdateDic:(NSMutableDictionary*)updateDic
{
    if (updateDic == nil || [updateDic count] == 0) {
        return self;
    }
    
    [updateDic enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL* stop) {
        if ([self objectForKey:key] != nil) {
            [self removeObjectForKey:key];
            [self setObject:@"" forKey:obj];
            [updateDic removeObjectForKey:key];
        }
    }];
    
    return self;
}

- (NSMutableDictionary*)minusByKeyArrayUseValue:(NSMutableArray*)keyArray modifyInput:(BOOL)mInput
{
    for (int i = 0; i < [keyArray count]; i++) {
        id arraykey = [keyArray objectAtIndex:i];
        [self enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL* stop) {
            if ([(NSString*)obj isEqualToString:arraykey]) {
                [self removeObjectForKey:key];
                [keyArray replaceObjectAtIndex:i withObject:key];
            }
        }];
    }
    
    return self;
}

@end

@implementation DCDBTableVersion

@end

