// Tracks whether a workspace doc is being edited (e.g., title, text, code block, or image caption).
// Used to hide the omnibox on phone widths during edit mode.
import { defineStore } from 'pinia';

export const useEditModeStore = defineStore('editMode', () => {
  const isEditing = ref(false);
  
  function setEditing(editing: boolean) {
    isEditing.value = editing;
  }
  
  return { isEditing, setEditing };
});