#include "SignerArchive.h"
#include "minizip/zip.h"
#include "minizip/unzip.h"
#include <copyfile.h>
#include <removefile.h>
#include <sys/clonefile.h>
#include <pthread.h>
#include <stdatomic.h>
#include <sys/stat.h>
#include <fts.h>
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

typedef struct { SGArchiveProgress callback; void *context; double last; uint64_t done, total, published; } SGWork;
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec/1e9; }
static int tick(SGWork *w, int force) {
    double t=now(); if (!force && !(w->done && !w->published) && t-w->last<0.05) return 0;
    w->last=t; w->published=w->done; return w->callback ? w->callback(w->done,w->total,w->context) : 0;
}
static int fail(char *error,size_t size,const char *message) { snprintf(error,size,"%s",message); return 1; }
typedef struct { char *path; struct stat st; } SGItem;
typedef struct { SGItem *items; size_t count,capacity; uint64_t bytes; } SGTree;
static void free_tree(SGTree *tree) { for(size_t i=0;i<tree->count;i++)free(tree->items[i].path);free(tree->items); }
static int tree_read(const char *root,SGTree *tree,SGWork *work,char *error,size_t size) {
    char *paths[]={ (char *)root,NULL }; FTS *walk=fts_open(paths,FTS_PHYSICAL|FTS_NOCHDIR,NULL);
    if (!walk) return fail(error,size,strerror(errno));
    FTSENT *entry; int result=0;
    while((entry=fts_read(walk))) {
        if(tick(work,0)) { result=2;break; }
        if(entry->fts_info==FTS_DP)continue;
        if(entry->fts_info==FTS_ERR||entry->fts_info==FTS_DNR||entry->fts_info==FTS_NS) { result=fail(error,size,"Unable to enumerate app files.");break; }
        if(entry->fts_info!=FTS_F&&entry->fts_info!=FTS_D&&entry->fts_info!=FTS_SL) { result=fail(error,size,"Unsupported app file type.");break; }
        if(tree->count==tree->capacity) {
            size_t n=tree->capacity ? tree->capacity*2 : 256;
            SGItem *next=realloc(tree->items,n*sizeof(SGItem));
            if(!next){result=fail(error,size,"Not enough memory for file list.");break;}
            tree->items=next;tree->capacity=n;
        }
        SGItem *item=&tree->items[tree->count++];item->path=strdup(entry->fts_path);item->st=*entry->fts_statp;
        if(!item->path){result=fail(error,size,"Not enough memory for file list.");break;}
        tree->bytes+=S_ISREG(item->st.st_mode) ? (uint64_t)item->st.st_size : 1;
    }
    fts_close(walk);return result;
}
static int mkdirs(const char *path) {
    char copy[PATH_MAX];if(strlen(path)>=sizeof(copy)){errno=ENAMETOOLONG;return -1;}
    strcpy(copy,path);
    for(char *p=copy+1;*p;p++)if(*p=='/'){*p=0;if(mkdir(copy,0700)&&errno!=EEXIST)return -1;*p='/';}
    if(mkdir(copy,0700)&&errno!=EEXIST)return -1;return 0;
}
static int safe_name(const char *name,size_t length) {
    if(!length || strlen(name)!=length || name[0]=='/' || strchr(name,'\\'))return 0;
    const char *part=name;
    for(const char *p=name;;p++)if(*p=='/'||!*p){if(p-part==2&&part[0]=='.'&&part[1]=='.')return 0;if(!*p)break;part=p+1;}
    return 1;
}
int SGExtractZIP(const char *source,const char *destination,SGArchiveProgress callback,void *context,char *error,size_t size) {
    unzFile input=unzOpen64(source);if(!input)return fail(error,size,"The ZIP or IPA cannot be opened.");
    SGWork work={callback,context,0,0,0};int result=0;uint64_t count=0;
    unz_file_info64 info;char name[PATH_MAX];int state=unzGoToFirstFile(input);
    // Preflight the complete central directory before creating any member.
    while(state==UNZ_OK) {
        if(unzGetCurrentFileInfo64(input,&info,name,sizeof(name),NULL,0,NULL,0)!=UNZ_OK ||
           info.size_filename>=sizeof(name)||!safe_name(name,info.size_filename)||
           ((info.external_fa>>16)&S_IFMT)==S_IFLNK || ++count>150000 ||
           info.uncompressed_size>UINT64_C(17179869184)-work.total) { result=fail(error,size,"The archive contains unsafe paths, links, or exceeds the 16 GB limit.");goto end; }
        work.total+=info.uncompressed_size ? info.uncompressed_size : 1;
        if(tick(&work,0)){result=2;goto end;}
        state=unzGoToNextFile(input);
    }
    if(state!=UNZ_END_OF_LIST_OF_FILE){result=fail(error,size,"The ZIP directory is damaged.");goto end;}
    if(mkdirs(destination)){result=fail(error,size,strerror(errno));goto end;}
    void *buffer=malloc(1024*1024);if(!buffer){result=fail(error,size,"Not enough memory to extract ZIP.");goto end;}
    char last_parent[PATH_MAX]="";
    state=unzGoToFirstFile(input);
    while(state==UNZ_OK) {
        if(tick(&work,0)){result=2;break;}
        if(unzGetCurrentFileInfo64(input,&info,name,sizeof(name),NULL,0,NULL,0)!=UNZ_OK){result=fail(error,size,"Invalid ZIP member.");break;}
        char path[PATH_MAX];
        if(snprintf(path,sizeof(path),"%s/%s",destination,name)>=(int)sizeof(path)){result=fail(error,size,"Archive path is too long.");break;}
        size_t length=strlen(path);
        if(length&&path[length-1]=='/') {
            if(mkdirs(path)){result=fail(error,size,strerror(errno));break;}
            work.done++;state=unzGoToNextFile(input);continue;
        }
        char parent[PATH_MAX];strcpy(parent,path);char *slash=strrchr(parent,'/');if(slash)*slash=0;
        if(strcmp(parent,last_parent)) {
            if(mkdirs(parent)){result=fail(error,size,strerror(errno));break;}
            strcpy(last_parent,parent);
        }
        if(unzOpenCurrentFile(input)!=UNZ_OK){result=fail(error,size,"Unable to decompress ZIP member.");break;}
        FILE *file=fopen(path,"wbx");
        if(!file){unzCloseCurrentFile(input);result=fail(error,size,strerror(errno));break;}
        uint64_t written=0;int bytes;
        while((bytes=unzReadCurrentFile(input,buffer,1024*1024))>0) {
            if(written+(uint64_t)bytes>info.uncompressed_size || fwrite(buffer,1,bytes,file)!=(size_t)bytes){result=fail(error,size,errno ? strerror(errno) : "Invalid extracted member size.");break;}
            written+=bytes;work.done+=bytes;
            if(tick(&work,0)){result=2;break;}
        }
        mode_t mode=(info.external_fa>>16)&0777;
        if(!result && fchmod(fileno(file),mode ? mode : 0644))result=fail(error,size,strerror(errno));
        if(fclose(file)&&!result)result=fail(error,size,strerror(errno));
        int crc=unzCloseCurrentFile(input);
        if(!result && crc==UNZ_CRCERROR)result=3;
        if(!result && (bytes<0||crc!=UNZ_OK||written!=info.uncompressed_size))result=fail(error,size,"The ZIP contains a damaged or truncated member.");
        if(result)break;
        if(!written)work.done++;
        state=unzGoToNextFile(input);
    }
    free(buffer);
    if(!result && state!=UNZ_END_OF_LIST_OF_FILE)result=fail(error,size,"The ZIP directory is damaged.");
    if(!result){work.done=work.total;if(tick(&work,1))result=2;}
end:
    unzClose(input);return result;
}
typedef struct { size_t tree_index; char path[PATH_MAX]; uint32_t crc; int ready, error; } SGPrepared;
typedef struct {
    SGTree *tree; SGPrepared *entries; size_t count,next,consumed;
    pthread_mutex_t mutex; pthread_cond_t condition;
    atomic_int stop; atomic_uint_fast64_t bytes;
    char directory[PATH_MAX];
} SGPool;
static void *compress_worker(void *opaque) {
    SGPool *pool=opaque;void *input=malloc(524288),*output=malloc(524288);
    while(1) {
        pthread_mutex_lock(&pool->mutex);
        while(!atomic_load(&pool->stop)&&pool->next<pool->count&&pool->next-pool->consumed>=4)pthread_cond_wait(&pool->condition,&pool->mutex);
        if(atomic_load(&pool->stop)||pool->next>=pool->count){pthread_mutex_unlock(&pool->mutex);break;}
        SGPrepared *entry=&pool->entries[pool->next++];pthread_mutex_unlock(&pool->mutex);
        SGItem *item=&pool->tree->items[entry->tree_index];
        snprintf(entry->path,sizeof(entry->path),"%s/%zu",pool->directory,entry->tree_index);
        FILE *source=fopen(item->path,"rb"),*target=fopen(entry->path,"wb");
        int error=!input||!output||!source||!target;z_stream stream={0};int initialized=0;
        if(!error){initialized=deflateInit2(&stream,1,Z_DEFLATED,-MAX_WBITS,DEF_MEM_LEVEL,Z_DEFAULT_STRATEGY)==Z_OK;error=!initialized;}
        uint64_t total=0;uint32_t crc=crc32(0,NULL,0);int finished=0;
        while(!error&&!finished&&!atomic_load(&pool->stop)) {
            size_t count=fread(input,1,524288,source);if(ferror(source)){error=1;break;}
            total+=count;crc=crc32(crc,input,(uInt)count);stream.next_in=input;stream.avail_in=(uInt)count;
            int flush=feof(source)?Z_FINISH:Z_NO_FLUSH;
            do {
                stream.next_out=output;stream.avail_out=524288;
                int status=deflate(&stream,flush);
                if(status!=Z_OK&&status!=Z_STREAM_END){error=1;break;}
                size_t n=524288-stream.avail_out;if(fwrite(output,1,n,target)!=n){error=1;break;}
                finished=status==Z_STREAM_END;
            } while(!error&&(stream.avail_out==0||flush==Z_FINISH&&!finished));
            atomic_fetch_add(&pool->bytes,count);
        }
        if(total!=(uint64_t)item->st.st_size||!finished)error=1;
        if(initialized)deflateEnd(&stream);
        if(source)fclose(source);if(target&&fclose(target))error=1;
        pthread_mutex_lock(&pool->mutex);entry->crc=crc;entry->error=error ? (errno ? errno : EIO) : 0;entry->ready=1;
        pthread_cond_broadcast(&pool->condition);pthread_mutex_unlock(&pool->mutex);
    }
    free(input);free(output);return NULL;
}
static int wait_prepared(SGPool *pool,SGPrepared *entry,SGWork *work,uint64_t small_done) {
    pthread_mutex_lock(&pool->mutex);
    while(!entry->ready) {
        struct timespec limit;clock_gettime(CLOCK_REALTIME,&limit);limit.tv_nsec+=50000000;
        if(limit.tv_nsec>=1000000000){limit.tv_nsec-=1000000000;limit.tv_sec++;}
        pthread_cond_timedwait(&pool->condition,&pool->mutex,&limit);
        work->done=small_done+atomic_load(&pool->bytes);
        if(tick(work,0)){atomic_store(&pool->stop,1);pthread_mutex_unlock(&pool->mutex);return 2;}
    }
    int failed=entry->error;pthread_mutex_unlock(&pool->mutex);return failed?1:0;
}

int SGWriteZIP(const char *payload,const char *destination,int compressed,SGArchiveProgress callback,void *context,char *error,size_t size) {
    SGTree tree={0};SGWork work={callback,context,0,0,0};int result=tree_read(payload,&tree,&work,error,size);
    if(result){free_tree(&tree);return result;}
    work.total=tree.bytes;
    SGPool pool={0};pool.tree=&tree;
    size_t large_count=0;
    for(size_t i=0;i<tree.count;i++)if(compressed&&S_ISREG(tree.items[i].st.st_mode)&&tree.items[i].st.st_size>=1048576)large_count++;
    pool.entries=calloc(large_count ? large_count : 1,sizeof(SGPrepared));
    if(!pool.entries){free_tree(&tree);return fail(error,size,"Not enough memory to create IPA.");}
    for(size_t i=0;i<tree.count;i++)if(compressed&&S_ISREG(tree.items[i].st.st_mode)&&tree.items[i].st.st_size>=1048576)
      pool.entries[pool.count++].tree_index=i;
    pthread_t threads[4];int thread_count=0;
    pthread_mutex_init(&pool.mutex,NULL);pthread_cond_init(&pool.condition,NULL);
    if(pool.count){
      snprintf(pool.directory,sizeof(pool.directory),"%s.parts.XXXXXX",destination);
      if(mkdtemp(pool.directory))for(int i=0;i<4;i++)if(!pthread_create(&threads[thread_count],NULL,compress_worker,&pool))thread_count++;
      if(!thread_count){if(pool.directory[0])rmdir(pool.directory);pool.count=0;}
    }
    uint64_t small_done=0;size_t large_index=0;
    zipFile zip=zipOpen64(destination,APPEND_STATUS_CREATE);
    if(!zip){result=fail(error,size,"Unable to create IPA.");goto cleanup;}
    void *buffer=malloc(1024*1024);if(!buffer){result=fail(error,size,"Not enough memory to create IPA.");goto end;}
    size_t root_length=strlen(payload);
    for(size_t i=0;i<tree.count;i++) {
        if(tick(&work,0)){result=2;break;}
        SGItem *item=&tree.items[i];char path[PATH_MAX];
        const char *suffix=item->path+root_length;
        if(snprintf(path,sizeof(path),"Payload%s%s",suffix,S_ISDIR(item->st.st_mode)?"/":"")>=(int)sizeof(path)){result=fail(error,size,"App path is too long.");break;}
        zip_fileinfo info={0};info.external_fa=((uLong)item->st.st_mode)<<16;
        struct tm t;localtime_r(&item->st.st_mtime,&t);
        info.tmz_date.tm_sec=t.tm_sec;info.tmz_date.tm_min=t.tm_min;info.tmz_date.tm_hour=t.tm_hour;
        info.tmz_date.tm_mday=t.tm_mday;info.tmz_date.tm_mon=t.tm_mon;info.tmz_date.tm_year=t.tm_year+1900;
        int method=compressed&&S_ISREG(item->st.st_mode)?Z_DEFLATED:0;
        SGPrepared *prepared=large_index<pool.count&&pool.entries[large_index].tree_index==i?&pool.entries[large_index]:NULL;
        if(prepared){result=wait_prepared(&pool,prepared,&work,small_done);if(result){if(result==1)snprintf(error,size,"Unable to compress %s: %s",item->path,strerror(prepared->error));break;}}
        int code=zipOpenNewFileInZip4_64(zip,path,&info,NULL,0,NULL,0,NULL,method,method?1:0,prepared!=NULL,-MAX_WBITS,DEF_MEM_LEVEL,Z_DEFAULT_STRATEGY,NULL,0,(3<<8)|20,1<<11,item->st.st_size>=UINT32_MAX);
        if(code!=ZIP_OK){result=fail(error,size,"Unable to create ZIP member.");break;}
        if(S_ISREG(item->st.st_mode)) {
            FILE *file=fopen(prepared?prepared->path:item->path,"rb");if(!file){result=fail(error,size,strerror(errno));zipCloseFileInZip(zip);break;}
            size_t n;uint64_t read=0;
            while((n=fread(buffer,1,1024*1024,file))) {
                if(zipWriteInFileInZip(zip,buffer,(unsigned)n)!=ZIP_OK){result=fail(error,size,"Unable to write IPA data.");break;}
                read+=n;if(!prepared)small_done+=n;work.done=small_done+atomic_load(&pool.bytes);if(tick(&work,0)){result=2;break;}
            }
            if(!result&&(ferror(file)||!prepared&&read!=(uint64_t)item->st.st_size))result=fail(error,size,"An app file changed while packaging.");
            fclose(file);
        } else if(S_ISLNK(item->st.st_mode)) {
            char resolved[PATH_MAX],link[PATH_MAX];ssize_t n=readlink(item->path,link,sizeof(link));
            if(!realpath(item->path,resolved)||strncmp(resolved,payload,root_length)||resolved[root_length]!='/'||n<0||zipWriteInFileInZip(zip,link,(unsigned)n)!=ZIP_OK)result=fail(error,size,"The app contains an unsafe symbolic link.");
            small_done++;
        } else small_done++;
        int closed=prepared?zipCloseFileInZipRaw64(zip,item->st.st_size,prepared->crc):zipCloseFileInZip(zip);
        if(prepared){unlink(prepared->path);large_index++;pthread_mutex_lock(&pool.mutex);pool.consumed++;pthread_cond_broadcast(&pool.condition);pthread_mutex_unlock(&pool.mutex);}
        work.done=small_done+atomic_load(&pool.bytes);
        if(closed!=ZIP_OK&&!result)result=fail(error,size,"Unable to finish ZIP member.");
        if(result)break;
    }
    free(buffer);
end:
    if(zipClose(zip,NULL)!=ZIP_OK&&!result)result=fail(error,size,"Unable to finish IPA.");
cleanup:
    atomic_store(&pool.stop,1);pthread_mutex_lock(&pool.mutex);pthread_cond_broadcast(&pool.condition);pthread_mutex_unlock(&pool.mutex);
    for(int i=0;i<thread_count;i++)pthread_join(threads[i],NULL);
    for(size_t i=0;i<pool.count;i++)if(pool.entries[i].path[0])unlink(pool.entries[i].path);
    if(pool.directory[0])rmdir(pool.directory);
    pthread_cond_destroy(&pool.condition);pthread_mutex_destroy(&pool.mutex);free(pool.entries);
    free_tree(&tree);
    if(!result){work.done=work.total;if(tick(&work,1))result=2;}
    if(result)unlink(destination);
    return result;
}
int SGCloneTree(const char *source,const char *destination,SGArchiveProgress callback,void *context,char *error,size_t size) {
    SGWork work={callback,context,0,0,1};
    if(tick(&work,1))return 2;
    // APFS can atomically clone the complete app hierarchy. This preserves
    // independence without 62k user/kernel transitions. Unsupported volumes
    // fall back to the cancellable native per-file implementation below.
    if(clonefile(source,destination,CLONE_NOFOLLOW)==0){work.done=work.total=1;return tick(&work,1)?2:0;}
    SGTree tree={0};int result=tree_read(source,&tree,&work,error,size);
    work.total=tree.count;if(result){free_tree(&tree);return result;}
    size_t prefix=strlen(source);
    for(size_t i=0;i<tree.count;i++) {
        if(tick(&work,0)){result=2;break;}
        SGItem *item=&tree.items[i];char path[PATH_MAX];
        if(snprintf(path,sizeof(path),"%s%s",destination,item->path+prefix)>=(int)sizeof(path)){result=fail(error,size,"App path is too long.");break;}
        if(S_ISDIR(item->st.st_mode)) {
            if(mkdir(path,0700)){result=fail(error,size,strerror(errno));break;}
        } else if(S_ISLNK(item->st.st_mode)) {
            char link[PATH_MAX];ssize_t n=readlink(item->path,link,sizeof(link)-1);
            if(n<0){result=fail(error,size,strerror(errno));break;}link[n]=0;
            if(symlink(link,path)){result=fail(error,size,strerror(errno));break;}
        } else if(clonefile(item->path,path,0) && copyfile(item->path,path,NULL,COPYFILE_DATA|COPYFILE_STAT|COPYFILE_NOFOLLOW|COPYFILE_EXCL)) {
            result=fail(error,size,strerror(errno));break;
        }
        work.done++;
    }
    for(size_t i=tree.count;!result&&i>0;i--)if(S_ISDIR(tree.items[i-1].st.st_mode)) {
        char path[PATH_MAX];snprintf(path,sizeof(path),"%s%s",destination,tree.items[i-1].path+prefix);
        if(chmod(path,tree.items[i-1].st.st_mode&0777))result=fail(error,size,strerror(errno));
    }
    free_tree(&tree);if(!result){work.done=work.total;if(tick(&work,1))result=2;}return result;
}

static int remove_confirm(removefile_state_t state,const char *path,void *context) {
    SGWork *work=context;
    return tick(work,0)?REMOVEFILE_STOP:REMOVEFILE_PROCEED;
}
int SGRemoveTree(const char *path,SGArchiveProgress callback,void *context,char *error,size_t size) {
    SGWork work={callback,context,0,0,0};
    if(tick(&work,1))return 2;
    struct stat info;
    if(lstat(path,&info))return fail(error,size,strerror(errno));
    if(!S_ISDIR(info.st_mode)) {
        if(unlink(path))return fail(error,size,strerror(errno));
        return 0;
    }
    removefile_state_t state=removefile_state_alloc();
    if(!state)return fail(error,size,"Unable to allocate file deletion state.");
    removefile_state_set(state,REMOVEFILE_STATE_CONFIRM_CALLBACK,remove_confirm);
    removefile_state_set(state,REMOVEFILE_STATE_CONFIRM_CONTEXT,&work);
    int result=removefile(path,state,REMOVEFILE_RECURSIVE);
    int saved=errno;removefile_state_free(state);
    if(result){if(tick(&work,1))return 2;return fail(error,size,strerror(saved));}
    // Completion means all filesystem entries were removed; there is no
    // private trash directory or pending background purge after this returns.
    if(lstat(path,&info)==0)return fail(error,size,"The item could not be fully deleted.");
    if(errno!=ENOENT)return fail(error,size,strerror(errno));
    return 0;
}
