/* =====================
   THEME LOGIC
===================== */

const toggleBtn = document.getElementById("theme-toggle");
const prefersDark = window.matchMedia("(prefers-color-scheme: dark)").matches;
const storedTheme = localStorage.getItem("theme");

setTheme(storedTheme || (prefersDark ? "dark" : "light"));

toggleBtn.addEventListener("click", () => {
    const current = document.documentElement.getAttribute("data-theme");
    setTheme(current === "dark" ? "light" : "dark");
});

function setTheme(theme) {
    document.documentElement.setAttribute("data-theme", theme);
    localStorage.setItem("theme", theme);
    toggleBtn.textContent = theme === "dark" ? "☀" : "🌙";
}

/* =====================
   DATA LOADING
===================== */

Promise.all([
    fetch("data.csv").then(r => r.text()),
    fetch("notes.csv").then(r => r.text())
]).then(([dataText, notesText]) => {
    const data = parseCSV(dataText);
    const notes = parseNotes(notesText);

    buildTable(data, notes);
    renderNotes(notes);
});

/* =====================
   CSV PARSER
===================== */

function parseCSV(text) {
    const rows = [];
    let row = [];
    let cell = "";
    let inQuotes = false;

    for (let i = 0; i < text.length; i++) {
        const char = text[i];

        if (char === '"') {
            if (inQuotes && text[i + 1] === '"') {
                cell += '"';
                i++;
            } else {
                inQuotes = !inQuotes;
            }
        } else if (char === "," && !inQuotes) {
            row.push(cell.trim());
            cell = "";
        } else if ((char === "\n" || char === "\r") && !inQuotes) {
            if (row.length || cell) {
                row.push(cell.trim());
                rows.push(row);
            }
            row = [];
            cell = "";
        } else {
            cell += char;
        }
    }

    if (row.length || cell) {
        row.push(cell.trim());
        rows.push(row);
    }

    return rows;
}

/* =====================
   NOTES
===================== */

function parseNotes(text) {
    const rows = parseCSV(text);
    const notes = {};
    rows.slice(1).forEach(([id, content]) => {
        notes[id] = content;
    });
    return notes;
}

function renderFootnotes(text, notes) {
    let result = text.replace(/\*\*/g, "[3]");

    return result.replace(/\[(\d+)\]/g, (_, n) => {
        return notes[n]
        ? `<sup data-note="${n}" title="${notes[n]}">${n}</sup>`
        : `<sup>${n}</sup>`;
    });
}

/* =====================
   TABLE
===================== */

function buildTable(rows, notes) {
    const table = document.getElementById("compare-table");

    const thead = document.createElement("thead");
    thead.innerHTML =
    "<tr>" + rows[0].map(h => `<th>${h}</th>`).join("") + "</tr>";
    table.appendChild(thead);

    const tbody = document.createElement("tbody");

    rows.slice(1).forEach(row => {
        const tr = document.createElement("tr");

        row.forEach(cell => {
            const td = document.createElement("td");

            let text = cell;
            let cls = "";

            if (cell.includes("|")) [text, cls] = cell.split("|");

            td.className = cls;
            td.innerHTML = renderFootnotes(text, notes);
            tr.appendChild(td);
        });

        tbody.appendChild(tr);
    });

    table.appendChild(tbody);
    enableColumnHover(table);
    enableFootnoteClicks();
}

/* =====================
   RENDER NOTES
===================== */

function renderNotes(notes) {
    const list = document.getElementById("notes-list");
    list.innerHTML = "";

    Object.keys(notes)
        .map(Number)
        .sort((a, b) => a - b)
        .forEach(id => {
        const li = document.createElement("li");
        li.id = `note-${id}`;
        li.value = id;              // ← КЛЮЧЕВОЕ ИЗМЕНЕНИЕ
        li.textContent = notes[id];
        list.appendChild(li);
    });
}

/* =====================
   INTERACTION
===================== */

function enableColumnHover(table) {
    table.querySelectorAll("td, th").forEach(cell => {
        cell.addEventListener("mouseenter", () => {
            const i = cell.cellIndex;
            table.querySelectorAll("tr").forEach(r => {
                if (r.cells[i]) r.cells[i].classList.add("hover-col");
            });
        });

        cell.addEventListener("mouseleave", () => {
            table.querySelectorAll(".hover-col")
                .forEach(c => c.classList.remove("hover-col"));
        });
    });
}

function enableFootnoteClicks() {
    document.querySelectorAll("sup[data-note]").forEach(sup => {
        sup.addEventListener("click", () => {
            const id = sup.dataset.note;
            const target = document.getElementById(`note-${id}`);
            if (!target) return;

            target.scrollIntoView({ behavior: "smooth", block: "center" });
            target.classList.add("note-active");

            setTimeout(() => {
                target.classList.remove("note-active");
            }, 2000);
        });
    });
}
