//
//  DCDBHandler.h
//  DCDBHandler
//
//  Created by chun.chen on 2018/3/23.
//  Copyright © 2018年 cc. All rights reserved.
//  基于FMDB的轻量级封装 暂时支持的数据格式只有 NSString, NSNumber, NSInteger

#import <Foundation/Foundation.h>

/* 数据迁移协议*/
@protocol DCDBMigrationProtocol

@required

/**
 *  返回该类数据的版本
 *
 *  @return 版本 - unsigned int 的 NSNumber  加入没有实现protocol默认为0, 第一个版本的class也请写为0.
 */
- (NSNumber *) dataVersionOfClass;

/**
 *  返回该类数据的primaryKey
 *
 *  @return string
 */
- (NSString *) primaryKey;

/**
 *  返回该版本相对上版本增加的字段
 *
 *  @param version - unsigned int的NSNumber 表示目标版本
 *
 *  @return 增加字段名(NSString)的数组
 */
- (NSArray *) addedKeysForVersion: (NSNumber *) version;

/**
 *  返回该版本相对上版本删除的字段
 *
 *  @param version - unsigned int的NSNumber 表示目标版本
 *
 *  @return 删除字段名(NSString)的数组
 */
- (NSArray *) deletedKeysForVersion: (NSNumber *) version;

/**
 *  返回该版本相对上版本重命名的字段
 *
 *  @param version - unsigned int的NSNumber 表示目标版本
 *
 *  @return 重命名字段的字典对象， key是上个版本的名字(NSString)  value是这个版本的名字(NSString)
 *  remove this due to sqlite doesn't support the column change
 */
- (NSDictionary *) renamedKeysForVersion: (NSNumber *) version;

@end

@interface NSMutableDictionary (SetOperation)

- (NSMutableDictionary *) addDic : (NSDictionary *) addDictionary;
- (NSMutableDictionary *) minusDic : (NSDictionary *) minusDictionary;

- (NSMutableDictionary *) addByKeyArray : (NSArray *) keyArray;
- (NSMutableDictionary *) minusByKeyArray : (NSMutableArray *) keyArray modifyInput: (BOOL) mInput;

- (NSMutableDictionary*)mergeWithUpdateDic:(NSMutableDictionary*)updateDic;
- (NSMutableDictionary*)minusByKeyArrayUseValue:(NSMutableArray*)keyArray modifyInput:(BOOL)mInput;

@end

@interface DCDBTableVersion : NSObject

@property (nonatomic, copy) NSString * tablename;
@property (nonatomic, copy) NSNumber * version;

@end


@interface DCDBHandler : NSObject

/**
 *  DB路径
 *
 *  @return DB路径
 */
+ (NSString*)dbFilePath;

/**
 *  拿取DB操作单例
 *
 *  @return DB操作实例-单例对象
 */
+ (DCDBHandler *)sharedInstance;

/**
 *  新插入或者更新数据
 *
 *  @return 操作成功还是失败
 */
- (BOOL)insertOrUpdateWithModelArr:(NSArray *)modelArr byPrimaryKey:(NSString *)pKey;

/**
 更新数据
 
 @param model 更新的类
 @param pkey 主键
 @param value 键值
 @return 操作成功还是失败
 */
- (BOOL)updateModel:(NSObject*)model primaryKey:(NSString*)pkey pKeyValue:(NSObject*)value;
/**
 *  查询符合条件的数据
 *
 *  @param modelClass 查询的类 (必须是NSObject的子类)
 *  @param key        查询类中的字段名
 *  @param value      查询类中的字段名的取值
 *  @param oKey       查询结果排序依据字段
 *  @param desc       查询结果是否按照降序排列
 *
 *  @return 查询到得的数据记录
 */
- (NSArray *) queryWithClass: (Class)modelClass key: (NSString *) key value :(NSObject *) value orderByKey:(NSString *)oKey desc:(BOOL)desc;
/**
 *  查询符合条件的数据 (page)
 *
 *  @param modelClass 查询的类 (必须是NSObject的子类)
 *  @param key        查询类中的字段名
 *  @param value      查询类中的字段名的取值
 *  @param page       查询的页数(从0页开始)
 *  @param offset     查询每页返回的个数
 *  @param oKey       查询结果排序依据字段
 *  @param desc       查询结果是否按照降序排列
 *
 *  @return 查询到得的数据记录
 */
- (NSArray*)queryWithClass:(Class)modelClass key:(NSString*)key value:(NSObject*)value page:(NSInteger)page offset:(NSInteger)offset orderByKey:(NSString*)oKey desc:(BOOL)desc;

/**
 查询符合条件的数据 (values)
 
 @param modelClass 查询的类 (必须是NSObject的子类)
 @param key 查询类中的字段名
 @param values 查询类中的字段名的取值数组
 @param oKey 查询结果排序依据字段
 @param desc 查询结果是否按照降序排列
 @return 查询到得的数据记录
 */
- (NSArray*)queryWithClass:(Class)modelClass key:(NSString*)key values:(NSArray*)values orderByKey:(NSString*)oKey desc:(BOOL)desc;

/**
 查询符合条件的数据
 
 @param modelClass 查询的类 (必须是NSObject的子类)
 @param appendingString 添加sql语句
 @return 查询到得的数据记录
 */
- (NSArray*)queryWithClass:(Class)modelClass appendingSQLString:(NSString *)appendingString;


/**
 使用函数查询数值
 
 @param func 函数名称 eg:MAX MIN AVG SUM
 @param modelClass 查询的类 (必须是NSObject的子类)
 @param key 查询类中的字段名
 @param appendingString 附加的sql语句
 @return 查询到得的数据
 */
- (NSNumber*)queryFunction:(NSString *)func withClass:(Class)modelClass key:(NSString*)key appendingSQLString:(NSString *)appendingString;

/**
 *  根据model删除符合条件的数据
 *
 *  @param arrOfmodel 删除model的数组
 *  @param key        删除model类的主键
 *
 *  @return 删除结果
 */
- (BOOL) deleteModels: (NSArray *)arrOfmodel withPrimaryKey: (NSString *)key;


/**
 根据类名删除条件数据
 
 @param modelClass 查询的类 (必须是NSObject的子类)
 @param key 查询类中的字段名
 @param value 查询类中的字段名的取值数组
 @return 删除结果
 */
- (BOOL) deleteWithClass:(Class)modelClass key:(NSString*)key value:(NSObject*)value;

/**
 *  删除该类型所有数据
 *
 *  @param modelClass 删除的目标类型
 *
 *  @return 删除结果
 */
- (BOOL) dropModels: (Class)modelClass;

@end
