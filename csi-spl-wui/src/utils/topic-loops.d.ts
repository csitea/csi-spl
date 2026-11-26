// Spec 182 row L3 (SPL-6034): the types of topic-loops.mjs, the loop JSON
// of section 7.1.2 (v0.4) that every loop route answers.

export interface TopicLoop {
  loop_id: string
  task_id: string
  prompt: string
  triggers: string[]
  interval_min?: number // exactly with every_n_minutes
  next_due_at?: string // RFC 3339, when every_hour or every_n_minutes is on
  state: 'on' | 'paused'
  set_by: string
  set_at: string
  fires_in_hour: number
  held_until?: string // when the cap holds it
  idle: '' | 'author_left' | 'author_no_right'
  keyword?: string // exactly with post_has_keyword
  idle_min?: number // exactly with no_reply_after_human
  daily_at?: string // hh:mm, exactly with daily_at
  daily_tz?: string // IANA zone, with daily_at
  daily_due_at?: string
}

/** POST / PUT body: each field only with its trigger. */
export interface TopicLoopBody {
  prompt: string
  triggers: string[]
  interval_min?: number
  keyword?: string
  idle_min?: number
  daily_at?: string
  daily_tz?: string
}

/** The dialog's form (emptyLoopForm, loopForm): one trigger (v0.11); `others` the rest of a loop stored with several. */
export interface TopicLoopForm {
  prompt: string
  trigger: string
  others: string[]
  interval: number
  keyword: string
  idle: number
  dailyAt: string
  dailyTz: string
}
