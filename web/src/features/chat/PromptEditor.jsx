import { useEffect, useRef } from "react";
import { history, historyKeymap, defaultKeymap } from "@codemirror/commands";
import { Compartment, EditorState, Prec } from "@codemirror/state";
import { EditorView, keymap, placeholder } from "@codemirror/view";

export default function PromptEditor({ value, onChange, onSubmit, onPasteImages, disabled }) {
  const hostRef = useRef(null);
  const viewRef = useRef(null);
  const submitRef = useRef(onSubmit);
  const changeRef = useRef(onChange);
  const pasteImagesRef = useRef(onPasteImages);
  const editableRef = useRef(new Compartment());

  useEffect(() => {
    submitRef.current = onSubmit;
    changeRef.current = onChange;
    pasteImagesRef.current = onPasteImages;
  }, [onSubmit, onChange, onPasteImages]);

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
          EditorView.domEventHandlers({
            paste: (event) => {
              const files = imageFilesFromClipboard(event.clipboardData);

              if (files.length === 0) return false;

              event.preventDefault();
              pasteImagesRef.current?.(files);
              return true;
            },
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

function imageFilesFromClipboard(clipboardData) {
  if (!clipboardData?.items) return [];

  const timestamp = clipboardTimestamp();

  return Array.from(clipboardData.items)
    .filter((item) => item.kind === "file" && item.type.startsWith("image/"))
    .map((item, index) => normalizeClipboardImageFile(item.getAsFile(), item.type, timestamp, index))
    .filter(Boolean);
}

function normalizeClipboardImageFile(file, mimeType, timestamp, index) {
  if (!file) return null;

  return new File([file], clipboardFileName(mimeType, timestamp, index), {
    type: mimeType || file.type || "application/octet-stream",
    lastModified: Date.now(),
  });
}

function clipboardFileName(mimeType, timestamp, index) {
  const extension = extensionForMimeType(mimeType);
  const paddedIndex = String(index + 1).padStart(2, "0");
  return `clipboard-${timestamp}-${paddedIndex}.${extension}`;
}

function clipboardTimestamp() {
  const now = new Date();
  const pad = (value) => String(value).padStart(2, "0");

  return [
    now.getFullYear(),
    pad(now.getMonth() + 1),
    pad(now.getDate()),
    "-",
    pad(now.getHours()),
    pad(now.getMinutes()),
    pad(now.getSeconds()),
  ].join("");
}

function extensionForMimeType(mimeType) {
  if (mimeType === "image/png") return "png";
  if (mimeType === "image/jpeg") return "jpg";
  if (mimeType === "image/gif") return "gif";
  if (mimeType === "image/webp") return "webp";
  return "bin";
}
