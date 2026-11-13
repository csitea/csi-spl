#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <sys/mman.h>
static double tv(struct timeval a){return a.tv_sec*1e6+a.tv_usec;}
static double now(){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec*1e6+t.tv_nsec/1e3;}
int main(int argc,char**argv){ size_t mb=atoi(argv[1]); int touch_child=atoi(argv[2]); int nohuge=argc>3&&atoi(argv[3]);
 size_t n=mb<<20; char*p=NULL;
 if(n){ p=malloc(n); if(nohuge) madvise((void*)(((unsigned long)p+4095)&~4095UL), n-4096, MADV_NOHUGEPAGE); memset(p,1,n);}
 int M=300; struct rusage s0,s1,c0,c1; getrusage(RUSAGE_SELF,&s0); getrusage(RUSAGE_CHILDREN,&c0); double t=now();
 for(int i=0;i<M;i++){ pid_t q=fork(); if(!q){ if(touch_child&&n) for(size_t j=0;j<n;j+=4096*touch_child) p[j]=2; _exit(0);} waitpid(q,0,0);}
 double w=now()-t; getrusage(RUSAGE_SELF,&s1); getrusage(RUSAGE_CHILDREN,&c1);
 printf("heap=%4zuMB thp=%s child_touch_every=%dpg: wall %6.0f us/fork, parent sys %5.0f, child sys %5.0f, child usr %4.0f us\n", mb, nohuge?"off":"sys", touch_child, w/M,(tv(s1.ru_stime)-tv(s0.ru_stime))/M,(tv(c1.ru_stime)-tv(c0.ru_stime))/M,(tv(c1.ru_utime)-tv(c0.ru_utime))/M);}
