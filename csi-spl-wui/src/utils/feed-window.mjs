/** One page of a feed: the first paint and every Load more. Its own module so
    a plugin that needs the number (plugins/lobby-warm) does not pull the live
    store into the entry chunk (CLE-35062). */
export const WINDOW = 30
