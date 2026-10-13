/** A JSON Schema object, or a $ref to one. */
export type JsonSchema = {
  $ref?: string;
  [key: string]: unknown;
};

/** A JSON Schema document (OpenAPI, JSON Schema draft). */
export type JsonSchemaDoc = Record<string, unknown>;

/** A PWA state object for __spoolPwa. */
export interface PwaState {
  ev?: Event;
  done?: number;
}