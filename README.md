## DCDBHandler
FMDB的封装，轻量级处理数据库框架。使用runtime直接存储对象

## 安装

#### CocoaPods
> pod 'DCDBHandler'

#### 手动安装
> 将DBHandler文件夹拽入项目中，导入头文件：#import "DCDBHandler.h"


## 注意
目前支持的对象类型 NSString, NSNumber, NSInteger

## 如何使用
```Objective-C
/**
 *  新插入或者更新数据
 *
 *  @return 操作成功还是失败
 */
- (BOOL)insertOrUpdateWithModelArr:(NSArray *)modelArr byPrimaryKey:(NSString *)pKey;

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
 *  根据model删除符合条件的数据
 *
 *  @param arrOfmodel 删除model的数组
 *  @param key        删除model类的主键
 *
 *  @return 删除结果
 */
- (BOOL) deleteModels: (NSArray *)arrOfmodel withPrimaryKey: (NSString *)key;

```

## 数据迁移 
遵守 DCDBMigrationProtocol 协议即可