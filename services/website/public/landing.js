'use strict';

const menuToggle = document.getElementById('menu-toggle');
const siteNav = document.getElementById('site-nav');
menuToggle.hidden = false;

function closeMenu() {
  siteNav.classList.remove('open');
  menuToggle.setAttribute('aria-expanded', 'false');
}

menuToggle.addEventListener('click', () => {
  const isOpen = siteNav.classList.toggle('open');
  menuToggle.setAttribute('aria-expanded', String(isOpen));
});
siteNav.querySelectorAll('a').forEach((link) => link.addEventListener('click', closeMenu));
document.addEventListener('keydown', (event) => {
  if (event.key === 'Escape' && siteNav.classList.contains('open')) {
    closeMenu();
    menuToggle.focus();
  }
});

// Prewritten examples illustrate the course structure. No AI requests or user data.
const courses = {
  sound: {
    title: 'Sound & music',
    pages: {
      root: {
        label: 'What makes a sound?',
        title: 'Same note. Different sound.',
        body: 'A piano and a guitar can play the same note, yet sound different. Part of that difference comes from the mix of harmonics in each sound.',
        children: ['harmonics', 'attack']
      },
      harmonics: {
        parent: 'root', label: 'Harmonics', question: 'Wait, what is a harmonic?',
        title: 'There is more than one vibration in a note.',
        body: 'A vibrating string can produce several frequencies at once. Harmonics are frequencies at whole-number multiples of a fundamental frequency. Their relative strengths help give a sound its character.',
        children: ['string']
      },
      string: {
        parent: 'harmonics', label: 'A vibrating string', question: 'How can one string make several frequencies?',
        title: 'One string. Several patterns.',
        body: 'A string can vibrate along its full length and in smaller sections at the same time. These patterns overlap. Each contributes a frequency to the sound you hear.',
        children: []
      },
      attack: {
        parent: 'root', label: 'The start of a note', question: 'Does the way a note starts matter too?',
        title: 'The first instant tells you a lot.',
        body: 'The beginning of a note is called its attack. A piano hammer strikes a string; a guitarist might pluck one. Those different starts help you recognize the instrument.',
        children: ['pluck']
      },
      pluck: {
        parent: 'attack', label: 'Where you pluck', question: 'What if I pluck near the bridge?',
        title: 'The same string can sound brighter.',
        body: 'Plucking nearer the bridge changes the mix of vibrations you excite. Higher harmonics tend to be more prominent, so the note often sounds brighter even though its pitch stays the same.',
        children: []
      }
    }
  },
  space: {
    title: 'Space & starlight',
    pages: {
      root: {
        label: 'Looking at starlight', title: 'The sky takes time to reach you.',
        body: 'Light travels at a finite speed. When you look at a star, you see light that left it in the past. More distant stars give you an older view.',
        children: ['year', 'sun']
      },
      year: {
        parent: 'root', label: 'A light-year', question: 'Is a light-year time or distance?',
        title: 'A year of travel, measured as distance.',
        body: 'A light-year is the distance light travels in a vacuum in one year. It is a unit of distance. A star ten light-years away is so far away that its light takes about ten years to reach us.',
        children: ['past']
      },
      past: {
        parent: 'year', label: 'Seeing the past', question: 'So am I really looking into the past?',
        title: 'You see the light that has arrived.',
        body: 'Yes. The light reaching you now carries information about the star when that light left. If the star changed after that moment, the news is still on its way.',
        children: []
      },
      sun: {
        parent: 'root', label: 'Sunlight', question: 'Does this happen with our Sun too?',
        title: 'Even sunlight arrives a little late.',
        body: 'Light from the Sun takes about eight minutes to reach Earth. The sunlight you see now left the Sun several minutes ago.',
        children: ['moon']
      },
      moon: {
        parent: 'sun', label: 'Moonlight', question: 'What about the Moon?',
        title: 'A much shorter trip.',
        body: 'The Moon reflects sunlight. Once that reflected light leaves the Moon, it takes about 1.3 seconds to reach Earth. The Moon is much closer to us than the Sun is.',
        children: []
      }
    }
  },
  bread: {
    title: 'The science of bread',
    pages: {
      root: {
        label: 'Why dough rises', title: 'A loaf begins with little bubbles.',
        body: 'In yeast bread, yeast produces carbon dioxide as it consumes sugars. The dough traps some of that gas, and the bubbles expand as the dough rises.',
        children: ['yeast', 'gluten']
      },
      yeast: {
        parent: 'root', label: 'Meet the yeast', question: 'Wait, is yeast alive?',
        title: 'A tiny living ingredient.',
        body: 'Baker\'s yeast is a single-celled fungus. As it uses sugars for energy, it produces carbon dioxide and alcohol through fermentation. That gas helps your dough rise.',
        children: ['cold']
      },
      cold: {
        parent: 'yeast', label: 'A slower rise', question: 'Why put dough in the fridge overnight?',
        title: 'Cold slows the yeast down.',
        body: 'Lower temperatures slow yeast activity, so dough generally rises more slowly in the fridge. The longer fermentation also gives flavors time to develop.',
        children: []
      },
      gluten: {
        parent: 'root', label: 'Holding the bubbles', question: 'What keeps the gas from escaping?',
        title: 'A stretchy network in the dough.',
        body: 'When wheat flour mixes with water, its gluten-forming proteins can build a network. Mixing and kneading help develop it. That stretchy network holds gas bubbles as they grow.',
        children: ['knead']
      },
      knead: {
        parent: 'gluten', label: 'Kneading dough', question: 'Is that why we knead bread?',
        title: 'You are helping build the structure.',
        body: 'Kneading helps develop and organize the gluten network. Dough becomes smoother and more elastic, better able to stretch around the gas bubbles produced during fermentation.',
        children: []
      }
    }
  }
};

let topic = 'sound';
let currentPage = 'root';
let visited = new Set(['root']);
const title = document.getElementById('demo-title');
const tree = document.getElementById('demo-tree');
const questions = document.getElementById('demo-questions');
const back = document.getElementById('demo-back');
const announcement = document.getElementById('demo-announcement');

function pagePath(id) {
  const path = [];
  while (id) {
    path.unshift(id);
    id = courses[topic].pages[id].parent;
  }
  return path;
}

function renderTree(id, list) {
  const page = courses[topic].pages[id];
  const row = document.createElement('li');
  const button = document.createElement('button');
  button.type = 'button';
  button.textContent = page.label;
  if (id === currentPage) button.setAttribute('aria-current', 'page');
  button.addEventListener('click', () => openPage(id));
  row.append(button);
  const children = page.children.filter((child) => visited.has(child));
  if (children.length) {
    const nested = document.createElement('ol');
    children.forEach((child) => renderTree(child, nested));
    row.append(nested);
  }
  list.append(row);
}

function render(focusPage = false) {
  const course = courses[topic];
  const page = course.pages[currentPage];
  document.getElementById('demo-course').textContent = course.title;
  document.getElementById('demo-breadcrumb').textContent = [course.title, ...pagePath(currentPage).slice(0, -1).map((id) => course.pages[id].label)].join(' / ');
  title.textContent = page.title;
  document.getElementById('demo-body').textContent = page.body;
  tree.replaceChildren();
  renderTree('root', tree);
  questions.replaceChildren();
  page.children.forEach((id) => {
    const button = document.createElement('button');
    button.type = 'button';
    button.textContent = course.pages[id].question;
    button.addEventListener('click', () => openPage(id));
    questions.append(button);
  });
  document.getElementById('demo-end').hidden = page.children.length > 0;
  back.hidden = !page.parent;
  if (page.parent) back.textContent = `Back to ${course.pages[page.parent].label}`;
  if (focusPage) title.focus({ preventScroll: true });
}

function openPage(id) {
  const isNew = !visited.has(id);
  currentPage = id;
  visited.add(id);
  render(true);
  const label = courses[topic].pages[id].label;
  announcement.textContent = isNew ? `New subpage: ${label}. Your earlier pages are still in the course.` : `Back to ${label}. Your explored pages are still here.`;
}

function resetCourse() {
  currentPage = 'root';
  visited = new Set(['root']);
  render();
  announcement.textContent = 'Choose a question to grow this course.';
}

document.querySelectorAll('[data-topic]').forEach((button) => {
  button.addEventListener('click', () => {
    if (topic === button.dataset.topic) return;
    topic = button.dataset.topic;
    document.querySelectorAll('[data-topic]').forEach((item) => {
      const selected = item === button;
      item.classList.toggle('active', selected);
      item.setAttribute('aria-pressed', String(selected));
    });
    resetCourse();
    announcement.textContent = `${courses[topic].title}. Choose a question to grow this course.`;
  });
});
back.addEventListener('click', () => {
  const parent = courses[topic].pages[currentPage].parent;
  if (parent) openPage(parent);
});
document.getElementById('demo-reset').addEventListener('click', resetCourse);
render();
document.getElementById('topic-picker').hidden = false;
document.getElementById('demo-controls').hidden = false;

// The header is dark glass over the hero, then takes the page surface once the hero scrolls away.
const header = document.querySelector('.site-header');
const hero = document.querySelector('.hero');
if (header && hero && 'IntersectionObserver' in window) {
  new IntersectionObserver(([entry]) => {
    header.classList.toggle('scrolled', !entry.isIntersecting);
  }, { rootMargin: '-68px 0px 0px 0px' }).observe(hero);
}

// The page follows the system appearance. A pick that differs from the system is remembered;
// picking the system's own appearance goes back to following it.
const themeToggle = document.getElementById('theme-toggle');
const systemDark = window.matchMedia('(prefers-color-scheme: dark)');
const systemTheme = () => (systemDark.matches ? 'dark' : 'light');
const currentTheme = () => document.documentElement.getAttribute('data-theme') || systemTheme();
function labelThemeToggle() {
  themeToggle.setAttribute('aria-label', currentTheme() === 'dark' ? 'Switch to light mode' : 'Switch to dark mode');
}
themeToggle.addEventListener('click', () => {
  const root = document.documentElement;
  const next = currentTheme() === 'dark' ? 'light' : 'dark';
  root.classList.add('theme-switching');
  try {
    if (next === systemTheme()) localStorage.removeItem('lf-theme');
    else localStorage.setItem('lf-theme', next);
  } catch {}
  if (next === systemTheme()) root.removeAttribute('data-theme');
  else root.setAttribute('data-theme', next);
  labelThemeToggle();
  requestAnimationFrame(() => requestAnimationFrame(() => root.classList.remove('theme-switching')));
});
systemDark.addEventListener('change', labelThemeToggle);
labelThemeToggle();

if ('IntersectionObserver' in window && !window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
  document.documentElement.classList.add('reveal-ready');
  const reveal = new IntersectionObserver((entries) => {
    entries.forEach((entry) => {
      if (!entry.isIntersecting) return;
      entry.target.classList.add('visible');
      reveal.unobserve(entry.target);
    });
  }, { rootMargin: '0px 0px -8% 0px' });
  document.querySelectorAll('[data-reveal]').forEach((element) => reveal.observe(element));
}
