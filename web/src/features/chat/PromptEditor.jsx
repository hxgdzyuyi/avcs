import { useEffect, useRef } from "react";
import { history, historyKeymap, defaultKeymap } from "@codemirror/commands";
import { Compartment, EditorState, Prec } from "@codemirror/state";
import { EditorView, keymap, placeholder } from "@codemirror/view";

export default function PromptEditor({ value, onChange, onSubmit, disabled }) {
  const hostRef = useRef(null);
  const viewRef = useRef(null);
  const submitRef = useRef(onSubmit);
  const changeRef = useRef(onChange);
  const editableRef = useRef(new Compartment());

  useEffect(() => {
    submitRef.current = onSubmit;
    changeRef.current = onChange;
  }, [onSubmit, onChange]);

  useEffect(() => {
    if (!hostRef.current) return undefined;

    const view = new EditorView({
      parent: hostRef.current,
      state: EditorState.create({
        doc: value,
        extensions: [
          history(),
          placeholder("Describe the image you want to create..."),
          EditorView.lineWrapping,
          EditorView.updateListener.of((update) => {
            if (update.docChanged) {
              changeRef.current(update.state.doc.toString());
            }
          }),
          Prec.high(
            keymap.of([
              {
                key: "Enter",
                run: () => {
                  submitRef.current();
                  return true;
                },
              },
              {
                key: "Mod-Enter",
                run: () => {
                  submitRef.current();
                  return true;
                },
              },
            ]),
          ),
          keymap.of([...defaultKeymap, ...historyKeymap]),
          editableRef.current.of(EditorView.editable.of(!disabled)),
        ],
      }),
    });

    viewRef.current = view;

    return () => {
      view.destroy();
      viewRef.current = null;
    };
  }, []);

  useEffect(() => {
    const view = viewRef.current;
    if (!view || view.state.doc.toString() === value) return;

    view.dispatch({
      changes: { from: 0, to: view.state.doc.length, insert: value },
    });
  }, [value]);

  useEffect(() => {
    const view = viewRef.current;
    if (!view) return;

    view.dispatch({
      effects: editableRef.current.reconfigure(EditorView.editable.of(!disabled)),
    });
  }, [disabled]);

  return <div className="prompt-editor" ref={hostRef} data-disabled={disabled ? "true" : "false"} />;
}
