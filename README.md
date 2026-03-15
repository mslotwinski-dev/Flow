# Flow
Bash

Flow to zaawansowany skrypt powłoki Bash (daemon) automatyzujący proces synchronizacji lokalnych katalogów z Dyskiem Google w czasie rzeczywistym. Narzędzie zostało stworzone w celu eliminacji konieczności ręcznego wykonywania kopii zapasowych, znacząco ułatwiając i zabezpieczając codzienną pracę w systemach z rodziny Unix.
Zasada działania:
Skrypt działa w tle i wykorzystuje mechanizmy jądra Linuxa (narzędzie inotifywait) do ciągłego monitorowania wskazanych katalogów pod kątem zdarzeń (tworzenie, modyfikacja, usuwanie plików). Po wykryciu zmiany, skrypt przeprowadza serię walidacji (np. sprawdzenie połączenia sieciowego, weryfikacja czy plik nie znajduje się na liście ignorowanych), a następnie wykorzystuje narzędzie rclone do natychmiastowego zsynchronizowania zmian z Dyskiem Google.
Kluczowe funkcjonalności (spełniające Twoje wymagania):
Zarządzanie demonem: Wbudowana obsługa komend start, stop, restart oraz status oparta na plikach PID.
Wysoka konfigurowalność: Wczytywanie parametrów z zewnętrznego pliku konfiguracyjnego (ścieżki, ignorowane rozszerzenia, limity wielkości plików).
Solidna walidacja: Odporność na błędy dzięki sprawdzaniu istnienia narzędzi, dostępności sieci i poprawności argumentów przed wywołaniem jakichkolwiek akcji.
Rozbudowane logowanie: Zapisywanie wszystkich operacji, błędów i ostrzeżeń do pliku logów wraz z precyzyjnymi znacznikami czasu.
Modułowy kod: Wykorzystanie ponad 10 złożonych instrukcji warunkowych i pętli (if, while, for, case) zamkniętych w czytelnych, dobrze skomentowanych funkcjach.
