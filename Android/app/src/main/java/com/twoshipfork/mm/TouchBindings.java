package com.twoshipfork.mm;

/** Independent game-action assignments for each integrated touch preset. */
final class TouchBindings {
    static final String[] KEYS = {"a","b","cl","cd","cr","cu","z","l","r","du","dd","dl","dr","start","fairy","map"};
    static final int NAVI = 5;
    static String preferenceKey(int style, int index) {
        return "touchBinding."+style+"."+KEYS[index];
    }
    static void assign(int[] actions, int style, int index, int value) {
        int old = actions[index];
        if (old == value) return;
        // The Map footer is fixed; Modern has no separate "fairy" button.
        for (int i=0; value!=0 && i<KEYS.length-1; i++) {
            if (i!=index && !(style==3 && i==14) && actions[i]==value) actions[i]=old;
        }
        actions[index]=value;
    }
    private static final int[] MASKS = {0,0x8000,0x4000,0x2000,0x10,0x20000,2,4,1,0x20,8,0x1000,0x800,0x400,0x200,0x100,0x10000,0x01000000,0x40,0x80};
    static int index(String key) {
        for (int i=0;i<KEYS.length;i++) if(KEYS[i].equals(key)) return i;
        return -1;
    }
    static int mask(int action, boolean naviOnL) {
        return mask(action,naviOnL,false);
    }
    static int mask(int action, boolean naviOnL, boolean paused) {
        if (action == NAVI && paused) return 8; // C-up is the pause-menu equip modifier.
        return action>=0&&action<MASKS.length ? MASKS[action] : 0;
    }
    static int slot(int action, boolean naviOnL) {
        switch(action) {
            case 1: return 9;
            case 2: return 0;
            case NAVI: return 8;
            case 6: return 1;
            case 7: return 2;
            case 8: return 3;
            case 12: return 4;
            case 13: return 5;
            case 14: return 6;
            case 15: return 7;
            default: return -1;
        }
    }
}
