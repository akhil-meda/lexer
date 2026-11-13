#include "stdio.h"

int m() {
    int x;
    int y;
    int z;
    scanf("%d %d",&x,&y);
    if (x > y) {
        z = x;
    } else {
        z = y;
    }
    p("%d",z);
}
